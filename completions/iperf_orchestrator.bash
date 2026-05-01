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

    local subcommands="init status ssh-setup check-iperf check-servers \
        start-servers create-scripts distribute-scripts run-tests \
        collect-results stop-servers cleanup parse-csv parse-cpu \
        make-pivot make-heatmap doctor results-summary all help"

    local global_flags="--port --duration -d --parallel -P --jobs -j \
        --start-delay --ssh-user -u --iperf-dir --remote-dir --python \
        --password-file --password-env --ask-password --retries \
        --dry-run -n --verbose -v --quiet -q -h --help"

    local run_modes="parallel sequential-host sequential-pair"

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
        --iperf-dir|--remote-dir|--password-file|--python)
            _filedir
            return ;;
        --port|--duration|-d|--parallel|-P|--jobs|-j|--start-delay|--retries|--password-env|--ssh-user|-u)
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
            COMPREPLY=( $(compgen -W "$run_modes --keep-going --resume --help" -- "$cur") )
            ;;
        init)
            _filedir
            ;;
        cleanup)
            COMPREPLY=( $(compgen -W "--yes --help" -- "$cur") )
            ;;
        status)
            COMPREPLY=( $(compgen -W "--json --help" -- "$cur") )
            ;;
        *)
            COMPREPLY=( $(compgen -W "--help" -- "$cur") )
            ;;
    esac
}

complete -F _iperf_orchestrator iperf_orchestrator.sh
complete -F _iperf_orchestrator ./iperf_orchestrator.sh
