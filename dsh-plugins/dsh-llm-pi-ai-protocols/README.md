# DSH per-model wire protocols

This optional Spark workspace plugin groups LiteLLM routes under one provider.
The `api` field on each model selects Chat Completions, Responses, or Anthropic
Messages. Model-specific compatibility settings and reasoning menus travel
with the route.

Use `spark ws setup --plugins protocols` to select the adapter. Spark generates
the model list. The native model picker can select the generated routes.

`adapter.patch` records the changes to the bundled DeepSeek adapter.
`gui/editor.patch` is the original local editor customization. Spark uses
the stock editor and manages its own catalog, so it does not patch the web
client during installation.
