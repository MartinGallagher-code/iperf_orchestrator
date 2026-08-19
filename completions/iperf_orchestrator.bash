# bash completion for iperf_orchestrator.sh
#
# Install:
#   source completions/iperf_orchestrator.bash
# Or for system-wide install on Debian/Ubuntu:
#   sudo cp completions/iperf_orchestrator.bash /etc/bash_completion.d/

_iperf_orchestrator() {
    local cur prev words cword
    _init_completion >/dev/null 2>&1 || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword="$COMP_CWORD"
    }

    local subcommands="gen start summarize stop clean run hints \
        status check-iperf check-servers \
        start-servers create-scripts distribute-scripts run-tests \
        collect-results stop-servers cleanup parse-csv parse-cpu \
        make-pivot make-heatmap doctor results-summary all help \
        help-advanced version"

    local global_flags="--plan --servers -s --output -o --run-id \
        --port --duration -d --streams -P --ssh-jobs -j --start-delay \
        --total-time --host-flows --bandwidth -b --length -l --window -w \
        --mss -M --no-nagle -N --bind -B --server-bind \
        --ssh-user -u --remote-dir --python \
        --dry-run -n --verbose -v --quiet -q \
        -h --help --help-advanced --version"

    local run_modes="parallel sequential-host sequential-pair rolling"

    # Find the first non-flag word: that's the subcommand (if any).
    local i sub=""
    for ((i=1; i<cword; i++)); do
        case "${words[i]}" in
            --*|-?) ;;
            *) sub="${words[i]}"; break ;;
        esac
    done

    # Value-taking flags: complete the value, not another flag.
    case "$prev" in
        --plan|--servers|-s|--output|-o|--python)
            _filedir
            return ;;
        --run-id|--port|--duration|-d|--streams|-P|--ssh-jobs|-j|--start-delay|\
        --total-time|--host-flows|--bandwidth|-b|--length|-l|--window|-w|\
        --mss|-M|--bind|-B|--server-bind|--remote-dir|--ssh-user|-u|--for|--watch)
            return ;;  # numeric/text values, no completion
    esac

    # Before the subcommand: complete subcommands and global flags.
    if [ -z "$sub" ]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=( $(compgen -W "$global_flags" -- "$cur") )
        else
            COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
        fi
        return
    fi

    # After the subcommand: subcommand-specific completion.
    case "$sub" in
        run-tests|all)
            COMPREPLY=( $(compgen -W "$run_modes --keep-going --help" -- "$cur") )
            ;;
        gen)
            COMPREPLY=( $(compgen -W "$run_modes --grid --help" -- "$cur") )
            ;;
        start)
            COMPREPLY=( $(compgen -W "$run_modes --keep-going --help" -- "$cur") )
            ;;
        run)
            COMPREPLY=( $(compgen -W "$run_modes --for --keep-going --help" -- "$cur") )
            ;;
        cleanup)
            COMPREPLY=( $(compgen -W "--yes --help" -- "$cur") )
            ;;
        status)
            COMPREPLY=( $(compgen -W "--watch --help" -- "$cur") )
            ;;
        *)
            COMPREPLY=( $(compgen -W "--help" -- "$cur") )
            ;;
    esac
}

complete -F _iperf_orchestrator iperf_orchestrator.sh
complete -F _iperf_orchestrator ./iperf_orchestrator.sh
