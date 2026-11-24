# node_exec <node> <cmd...>: runs a command on a cluster node, stdin passed through; sourced, not run
# NODE_EXEC=lima: Lima VM name; ssh: host alias or NODE_SSH_USER@<node>, extra flags in NODE_SSH_OPTS;
# docker: node container (kind)
node_exec() {
  local node=$1
  shift
  case $NODE_EXEC in
    lima) limactl shell --workdir / "$node" "$@" ;;
    # ssh joins its arguments into one remote command line, so quote them like limactl does
    ssh) ssh -T ${NODE_SSH_OPTS:-} "${NODE_SSH_USER:+$NODE_SSH_USER@}$node" "$(printf '%q ' "$@")" ;;
    # node containers run as root and have no sudo
    docker)
      [[ $1 == sudo ]] && shift
      docker exec -i "$node" "$@"
      ;;
    *) echo "unknown NODE_EXEC '$NODE_EXEC' (lima, ssh, docker)" >&2; return 2 ;;
  esac
}
