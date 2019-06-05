SSH_AGENT_BIND="$HOME/.ssh/ssh-agent-bind"

function validate_identity() {
  ssh-add -l 2> /dev/null 1>&2
}

function add_identity() {
  ssh-add -t 1d
}

function extract_pid_from_ps_output_line() {
  local process_line="$1"
  local pid_index=$2

  local pid=$(
    echo $process_line \
    | sed -E 's/\s*//;s/\s+/,/g' \
    | cut -d ',' -f 1)

  echo $pid
}

function ensure_correct_ssh_agent_is_running() {
  if [ ! -S "$SSH_AGENT_BIND" ]; then
    return 1
  fi

  local ssh_agents="$(get_agents_process_list)"

  if [ -z "$ssh_agents" ]; then
    return 1
  fi

  local ssh_agent_instance_count="$(echo "$ssh_agents" | wc -l)"

  if [ $ssh_agent_instance_count -gt 1 ]; then
    return 1
  fi

  echo $(extract_pid_from_ps_output_line "$ssh_agents" $(find_pid_column_index_from_ps_output))
}

function setup_environment() {
  local pid=$1

  export SSH_AGENT_PID=$pid
  export SSH_AUTH_SOCK=$SSH_AGENT_BIND
}

function clear_environment() {
  unset SSH_AGENT_PID
  unset SSH_AUTH_SOCK
}

function remove_orphan_socket() {
  [ -S "$SSH_AGENT_BIND" ] && rm -f "$SSH_AGENT_BIND"
}

function prune_system_from_old_agent() {
  clear_environment \
  && kill_old_agents_processs \
  && remove_orphan_socket
}

function register_identity() {
  validate_identity \
  || add_identity
}

function try_connect_existing_agent {
  local ssh_agent_pid=
  ssh_agent_pid=$(ensure_correct_ssh_agent_is_running) \
  && setup_environment "$ssh_agent_pid" \
  && register_identity \
  || {
    prune_system_from_old_agent \
    && return 1;
  }
}

function spawn_new_agent() {
  eval $(ssh-agent -a "$SSH_AGENT_BIND")
}

function try_connect_new_agent() {
  spawn_new_agent \
  && add_identity
}

function ssh_authenticate() {
  try_connect_existing_agent \
  || try_connect_new_agent
}

function get_ps_command() {
  ps aux 2> /dev/null 1>&2 && echo "ps aux" && return
  ps -efl 2> /dev/null 1>&2 && echo "ps -efl" && return
}

function get_agents_process_list() {
  local ps_command="$(get_ps_command)"
  local process_list="$(eval $ps_command | grep ssh-agent | grep -v grep)"

  echo "$process_list"
}

function find_pid_column_index_from_ps_output() {
  local header="$(eval $(get_ps_command) | head -n 1)"

  local column=
  local index=1
  for column in $header; do
    [ "$column" = 'PID' ] && break \
    || index=$(( index + 1 ))
  done

  echo $index
}

function extract_old_agent_pid_from_process_line() {
  local pid="$(extract_pid_from_ps_output_line "$1" $2)"

  [ -z $SSH_AGENT_PID ] && echo $pid && return 0
  [ $pid -ne $SSH_AGENT_PID ] && echo $pid
}

function extract_pids_from_process_list() {
  local process_list="$1"
  local pid_column_index=$(find_pid_column_index_from_ps_output)
  local pids=

  local process_line=
  while read process_line; do
    pids="$pids $(extract_old_agent_pid_from_process_line "$process_line" $pid_column_index)"
  done << EOF
$process_list
EOF

  echo "$pids"
}

function get_old_agent_pids() {
  local agents_process_list="$(get_agents_process_list)"

  echo $(extract_pids_from_process_list "$agents_process_list")
}

function kill_old_agents_processs() {
  local agent_pids=$(get_old_agent_pids)

  local pid=
  for pid in $agent_pids; do
    kill $pid
  done
}

function ssh_auth_() {
  ssh_authenticate \
  && kill_old_agents_processs
}

alias ssh-auth='ssh_auth_'