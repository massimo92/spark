"""Greedy same-request suffix lookup for DSpark proposals."""

import torch

from vllm.triton_utils import tl, triton

SCORE_STRIDE = tl.constexpr(1 << 32)


@triton.jit
def _suffix_lookup_kernel(
    all_token_ids_ptr,
    all_token_ids_stride,
    total_len_ptr,
    idx_mapping_ptr,
    idx_mapping_stride,
    out_tokens_ptr,
    out_tokens_stride,
    out_len_ptr,
    out_valid_ptr,
    search_max,
    k: tl.constexpr,
    NMAX: tl.constexpr,
    NMIN: tl.constexpr,
    BLOCK: tl.constexpr,
    BLOCK_KT: tl.constexpr,
):
    req = tl.program_id(0)
    req_state = tl.load(idx_mapping_ptr + req * idx_mapping_stride)
    if req_state < 0:
        return
    tl.store(out_len_ptr + req, 0)
    tl.store(out_valid_ptr + req, 0)
    total_len = tl.load(total_len_ptr + req_state)
    if total_len < NMIN + 2:
        return
    base = all_token_ids_ptr + req_state.to(tl.int64) * all_token_ids_stride
    end_of_suffix = total_len - 1
    hi = end_of_suffix
    lo = tl.maximum(NMIN - 1, total_len - search_max)
    best = tl.full([], -1, tl.int64)
    for start in range(lo, hi, BLOCK):
        end = start + tl.arange(0, BLOCK)
        alive = (end < hi) & (end >= lo)
        for j in range(NMIN):
            source = tl.load(base + end_of_suffix - j)
            candidate = tl.load(
                base + end - j, mask=alive & ((end - j) >= 0), other=-1
            )
            alive = alive & (candidate == source)
        if tl.max(alive.to(tl.int32)) > 0:
            match = tl.where(alive, NMIN, 0)
            longer = alive
            for j in range(NMIN, NMAX):
                source = tl.load(
                    base + end_of_suffix - j,
                    mask=(end_of_suffix - j) >= 0,
                    other=-2,
                )
                candidate = tl.load(
                    base + end - j,
                    mask=longer & ((end - j) >= 0),
                    other=-1,
                )
                longer = longer & (candidate == source)
                match = tl.where(longer, match + 1, match)
            score = tl.where(
                alive,
                match.to(tl.int64) * SCORE_STRIDE + end.to(tl.int64),
                -1,
            )
            best = tl.maximum(best, tl.max(score, axis=0))
    if best < 0:
        return
    match_len = (best // SCORE_STRIDE).to(tl.int32)
    end = (best % SCORE_STRIDE).to(tl.int32)
    valid = tl.minimum(k, end_of_suffix - end)
    idx = tl.arange(0, BLOCK_KT)
    tokens = tl.load(base + end + 1 + idx, mask=idx < valid, other=0)
    tl.store(out_tokens_ptr + req * out_tokens_stride + idx, tokens, mask=idx < k)
    tl.store(out_len_ptr + req, match_len)
    tl.store(out_valid_ptr + req, valid)


@triton.jit
def _fuse_lookup_kernel(
    draft_tokens_ptr,
    draft_stride,
    lookup_tokens_ptr,
    lookup_stride,
    match_len_ptr,
    valid_ptr,
    idx_mapping_ptr,
    idx_mapping_stride,
    hits_ptr,
    nmin,
    nstrong,
    agree_min,
    k: tl.constexpr,
    BLOCK_KT: tl.constexpr,
):
    req = tl.program_id(0)
    if tl.load(idx_mapping_ptr + req * idx_mapping_stride) < 0:
        return
    idx = tl.arange(0, BLOCK_KT)
    kmask = idx < k
    match_len = tl.load(match_len_ptr + req)
    valid = tl.load(valid_ptr + req)
    drafted = tl.load(
        draft_tokens_ptr + req * draft_stride + idx, mask=kmask, other=0
    )
    looked = tl.load(
        lookup_tokens_ptr + req * lookup_stride + idx, mask=kmask, other=0
    ).to(tl.int64)
    disagree = (drafted != looked) & (idx < valid) & kmask
    agreement = tl.minimum(tl.min(tl.where(disagree, idx, k)), valid)
    take = (match_len >= nstrong) | (
        (match_len >= nmin) & (agreement >= agree_min)
    )
    use = take & (idx < valid) & kmask
    tl.store(draft_tokens_ptr + req * draft_stride + idx, looked, mask=use)
    tl.atomic_add(hits_ptr, take.to(tl.int64))


def suffix_lookup(
    all_token_ids: torch.Tensor,
    total_len: torch.Tensor,
    idx_mapping: torch.Tensor,
    num_reqs: int,
    k: int,
    idx_mapping_stride: int,
    nmax: int,
    nmin: int,
    search_max: int,
    out_tokens: torch.Tensor,
    out_len: torch.Tensor,
    out_valid: torch.Tensor,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    _suffix_lookup_kernel[(num_reqs,)](
        all_token_ids,
        all_token_ids.stride(0),
        total_len,
        idx_mapping,
        idx_mapping_stride,
        out_tokens,
        out_tokens.stride(0),
        out_len,
        out_valid,
        search_max,
        k=k,
        NMAX=nmax,
        NMIN=nmin,
        BLOCK=1024,
        BLOCK_KT=triton.next_power_of_2(k),
        num_warps=4,
    )
    return out_tokens, out_len, out_valid


def fuse_lookup(
    draft_tokens: torch.Tensor,
    lookup_tokens: torch.Tensor,
    match_len: torch.Tensor,
    valid: torch.Tensor,
    idx_mapping: torch.Tensor,
    hits: torch.Tensor,
    num_reqs: int,
    k: int,
    idx_mapping_stride: int,
    nmin: int,
    nstrong: int,
    agree_min: int,
) -> None:
    _fuse_lookup_kernel[(num_reqs,)](
        draft_tokens,
        draft_tokens.stride(0),
        lookup_tokens,
        lookup_tokens.stride(0),
        match_len,
        valid,
        idx_mapping,
        idx_mapping_stride,
        hits,
        nmin,
        nstrong,
        agree_min,
        k=k,
        BLOCK_KT=triton.next_power_of_2(k),
        num_warps=1,
    )
