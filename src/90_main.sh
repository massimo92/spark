# --- Main ---
main() {
  case "${1:-}:${2:-}" in
    status:--json|status:--quiet|ws:status|doctor:*|ws:doctor) ;;
    *) check_for_updates ;;
  esac

  case "${1:-}" in
    run)          shift; cmd_run "$@" ;;
    alias)        shift; cmd_alias "$@" ;;
    calibrate)    shift; cmd_calibrate "$@" ;;
    dashboard)    shift; cmd_dashboard "$@" ;;
    stop)         shift; cmd_stop "$@" ;;
    down)         shift; cmd_down "$@" ;;
    pull)         shift; cmd_pull "$@" ;;
    models)       shift; cmd_models "$@" ;;
    list)         cmd_list ;;
    rm)           shift; cmd_rm "$@" ;;
    status)       shift; cmd_status "$@" ;;
    logs)         shift; cmd_logs "$@" ;;
    doctor)       shift; cmd_doctor "$@" ;;
    setup)        shift; cmd_setup "$@" ;;
    ws)           shift; cmd_workspace "$@" ;;
    update)       cmd_update ;;
    gateway)      shift; cmd_gateway "$@" ;;
    reinstall)    shift; cmd_reinstall "$@" ;;
    uninstall)    shift; cmd_uninstall "$@" ;;
    config)       shift; cmd_config "$@" ;;
    architecture) cmd_architecture ;;
    version)      printf "spark v%s\n" "$VERSION" ;;
    __detect)     printf 'os=%s arch=%s accel=%s backend=%s\n' "$SPARK_OS" "$SPARK_ARCH" "$ACCEL" "$BACKEND" ;;
    help|--help|-h|"") cmd_help ;;
    *)            die "Unknown command: $1" "Run 'spark help' for usage" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
