# sourced by demo/demo.tape: c <n> erases its own command line and prints caption n
# (vhs cannot type non-ASCII characters, so the Slovak captions come from a file)
c() { printf '\033[1A\033[2K\033[1;34m# %s\033[0m\n' "$(sed -n "${1}p" demo/captions.txt)"; }
