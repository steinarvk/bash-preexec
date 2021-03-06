#!/usr/bin/env bats

setup() {
  PROMPT_COMMAND=''        # in case the invoking shell has set this
  history -s fake command  # preexec requires there be some history
  __bp_delay_install="true"
  source "${BATS_TEST_DIRNAME}/../bash-preexec.sh"
}

bp_install() {
  __bp_install_after_session_init
  eval "$PROMPT_COMMAND"
}

test_echo() {
  echo "test echo"
}

test_preexec_echo() {
  printf "%s\n" "$1"
}

@test "__bp_install_after_session_init should exit with 1 if we're not using bash" {
  unset BASH_VERSION
  run '__bp_install_after_session_init'
  [[ $status == 1 ]]
  [[ -z "$output" ]]
}

@test "__bp_install should exit if it's already installed" {
  bp_install

  run '__bp_install'
  [[ $status == 1 ]]
  [[ -z "$output" ]]
}

@test "__bp_install should remove trap logic and itself from PROMPT_COMMAND" {
  __bp_install_after_session_init

  [[ "$PROMPT_COMMAND" == *"trap DEBUG"* ]]
  [[ "$PROMPT_COMMAND" == *"__bp_install"* ]]

  eval "$PROMPT_COMMAND"

  [[ "$PROMPT_COMMAND" != *"trap DEBUG"* ]]
  [[ "$PROMPT_COMMAND" != *"__bp_install"* ]]
}

@test "__bp_install should preserve an existing DEBUG trap" {
  trap_invoked_count=0
  foo() { (( trap_invoked_count += 1 )); }

  # note setting this causes BATS to mis-report the failure line when this test fails
  trap foo DEBUG
  [[ "$(trap -p DEBUG | cut -d' ' -f3)" == "'foo'" ]]

  bp_install
  trap_count_snapshot=$trap_invoked_count

  [[ "$(trap -p DEBUG | cut -d' ' -f3)" == "'__bp_preexec_invoke_exec" ]]
  [[ "${preexec_functions[*]}" == *"__bp_original_debug_trap"* ]]

  __bp_interactive_mode # triggers the DEBUG trap

  # ensure the trap count is still being incremented after the trap's been overwritten
  (( trap_count_snapshot < trap_invoked_count ))
}

@test "PROMPT_COMMAND=\"\$PROMPT_COMMAND; foo\" should work" {
    bp_install

    PROMPT_COMMAND="$PROMPT_COMMAND; true"
    eval "$PROMPT_COMMAND"
}

@test "No functions defined for preexec should simply return" {
    __bp_interactive_mode

    run '__bp_preexec_invoke_exec' 'true'
    [[ $status == 0 ]]
    [[ -z "$output" ]]
}

@test "precmd should execute a function once" {
    precmd_functions+=(test_echo)
    run '__bp_precmd_invoke_cmd'
    [[ $status == 0 ]]
    [[ "$output" == "test echo" ]]
}

@test "precmd should set \$? to be the previous exit code" {
    echo_exit_code() {
      echo "$?"
    }
    return_exit_code() {
      return $1
    }
    # Helper function is necessary because Bats' run doesn't preserve $?
    set_exit_code_and_run_precmd() {
      return_exit_code 251
      __bp_precmd_invoke_cmd
    }

    precmd_functions+=(echo_exit_code)
    run 'set_exit_code_and_run_precmd'
    [[ $status == 0 ]]
    [[ "$output" == "251" ]]
}

@test "precmd should set \$_ to be the previous last arg" {
    echo_last_arg() {
      echo "$_"
    }
    precmd_functions+=(echo_last_arg)

    bats_trap=$(trap -p DEBUG)
    trap DEBUG # remove the Bats stack-trace trap so $_ doesn't get overwritten
    : "last-arg"
    __bp_preexec_invoke_exec "$_"
    eval "$bats_trap" # Restore trap
    run '__bp_precmd_invoke_cmd'
    [[ $status == 0 ]]
    [[ "$output" == "last-arg" ]]
}

@test "preexec should execute a function with the last command in our history" {
    preexec_functions+=(test_preexec_echo)
    __bp_interactive_mode
    git_command="git commit -a -m 'committing some stuff'"
    history -s $git_command

    run '__bp_preexec_invoke_exec'
    [[ $status == 0 ]]
    [[ "$output" == "$git_command" ]]
}

@test "preexec should execute multiple functions in the order added to their arrays" {
    fun_1() { echo "$1 one"; }
    fun_2() { echo "$1 two"; }
    preexec_functions+=(fun_1)
    preexec_functions+=(fun_2)
    __bp_interactive_mode

    run '__bp_preexec_invoke_exec'
    [[ $status == 0 ]]
    [[ "${#lines[@]}" == 2 ]]
    [[ "${lines[0]}" == "fake command one" ]]
    [[ "${lines[1]}" == "fake command two" ]]
}

@test "preecmd should execute multiple functions in the order added to their arrays" {
    fun_1() { echo "one"; }
    fun_2() { echo "two"; }
    precmd_functions+=(fun_1)
    precmd_functions+=(fun_2)

    run '__bp_precmd_invoke_cmd'
    [[ $status == 0 ]]
    [[ "${#lines[@]}" == 2 ]]
    [[ "${lines[0]}" == "one" ]]
    [[ "${lines[1]}" == "two" ]]
}

@test "preexec should execute a function with IFS defined to local scope" {
    IFS=_
    name_with_underscores_1() { parts=(1_2); echo $parts; }
    preexec_functions+=(name_with_underscores_1)

    __bp_interactive_mode
    run '__bp_preexec_invoke_exec'
    [[ $status == 0 ]]
    [[ "$output" == "1 2" ]]
}

@test "precmd should execute a function with IFS defined to local scope" {
    IFS=_
    name_with_underscores_2() { parts=(2_2); echo $parts; }
    precmd_functions+=(name_with_underscores_2)
    run '__bp_precmd_invoke_cmd'
    [[ $status == 0 ]]
    [[ "$output" == "2 2" ]]
}

@test "preexec should set \$? to be the exit code of preexec_functions" {
    return_nonzero() {
      return 1
    }
    preexec_functions+=(return_nonzero)

    __bp_interactive_mode

    run '__bp_preexec_invoke_exec'
    [[ $status == 1 ]]
}

@test "in_prompt_command should detect if a command is part of PROMPT_COMMAND" {

    PROMPT_COMMAND="precmd_invoke_cmd; something;"
    run '__bp_in_prompt_command' "something"
    [[ $status == 0 ]]

    run '__bp_in_prompt_command' "something_else"
    [[ $status == 1 ]]

    # Should trim commands and arguments here.
    PROMPT_COMMAND=" precmd_invoke_cmd ; something ; some_stuff_here;"
    run '__bp_in_prompt_command' " precmd_invoke_cmd "
    [[ $status == 0 ]]

    PROMPT_COMMAND=" precmd_invoke_cmd ; something ; some_stuff_here;"
    run '__bp_in_prompt_command' " not_found"
    [[ $status == 1 ]]

}

@test "__bp_adjust_histcontrol should remove ignorespace and ignoreboth" {

    # Should remove ignorespace
    HISTCONTROL="ignorespace:ignoredups:*"
    __bp_adjust_histcontrol
    [[ "$HISTCONTROL" == ":ignoredups:*" ]]

    # Should remove ignoreboth and replace it with ignoredups
    HISTCONTROL="ignoreboth"
    __bp_adjust_histcontrol
    [[ "$HISTCONTROL" == "ignoredups:" ]]

    # Handle a few inputs
    HISTCONTROL="ignoreboth:ignorespace:some_thing_else"
    __bp_adjust_histcontrol
    echo "$HISTCONTROL"
    [[ "$HISTCONTROL" == "ignoredups:::some_thing_else" ]]

}

@test "preexec should respect HISTTIMEFORMAT" {
    preexec_functions+=(test_preexec_echo)
    __bp_interactive_mode
    git_command="git commit -a -m 'committing some stuff'"
    HISTTIMEFORMAT='%F %T '
    history -s $git_command

    run '__bp_preexec_invoke_exec'
    [[ $status == 0 ]]
    [[ "$output" == "$git_command" ]]
}

@test "preexec should not strip whitespace from commands" {
    preexec_functions+=(test_preexec_echo)
    __bp_interactive_mode
    history -s " this command has whitespace "

    run '__bp_preexec_invoke_exec'
    [[ $status == 0 ]]
    [[ "$output" == " this command has whitespace " ]]
}

@test "preexec should preserve multi-line strings in commands" {
    preexec_functions+=(test_preexec_echo)
    __bp_interactive_mode
    history -s "this 'command contains
a multiline string'"
    run '__bp_preexec_invoke_exec'
    [[ $status == 0 ]]
    [[ "$output" == "this 'command contains
a multiline string'" ]]
}

@test "preexec should work on options to 'echo' commands" {
    preexec_functions+=(test_preexec_echo)
    __bp_interactive_mode
    history -s -- '-n'
    run '__bp_preexec_invoke_exec'
    [[ $status == 0 ]]
    [[ "$output" == '-n' ]]
}
