tmux new-session -d -s zenn -n writer -c "${pwd}"
sleep 0.5
tmux send-keys -t "zenn:writer" "claude --dangerously-skip-permissions" C-m
tmux select-pane -t "zenn:writer" -T "writer"
