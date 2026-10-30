# The statusline's running-tasks segment (statusline.sh): each task with how far along it
# is and how long is left, estimated from the median of the last ten durations of its kind,
# and, for several tasks, when all of them will be done (a lane's tasks add up, lanes run
# at once). Inputs: $now (epoch seconds), $tasks ([{key, lane, label, start}]), $hist (the
# duration records, [{key, seconds}]).
def human: if . >= 3600 then "\(. / 3600 | floor)h\((. % 3600) / 60 | floor)m"
           elif . >= 60 then "\(. / 60 | ceil)m" else "\(.)s" end;
# Time so far rounds DOWN (a minute and a second has run one minute); time left rounds UP
# (a second left is still a minute to wait).
def ago: if . >= 3600 then "\(. / 3600 | floor)h\((. % 3600) / 60 | floor)m"
         elif . >= 60 then "\(. / 60 | floor)m" else "\(.)s" end;
def median: sort | if length == 0 then null else .[(length / 2) | floor] end;
($hist | map(select(type == "object"))) as $h
| [ $tasks[]
    | . as $t
    | ($now - $t.start) as $elapsed
    | ([$h[] | select(.key == $t.key) | .seconds] | .[-10:] | median) as $est
    | $t + { elapsed: $elapsed, est: $est,
             left: (if $est == null then null else ([$est - $elapsed, 0] | max) end),
             pct: (if $est == null or $est == 0 then null
                   else ([($elapsed * 100 / $est) | floor, 95] | min) end) } ] as $rows
| ($rows | map(
    if .est == null then "\(.label) \(.elapsed | ago)"
    elif .left == 0 then "\(.label) \(.pct)% finishing"
    else "\(.label) \(.pct)% ~\(.left | human) left" end) | join(" · ")) as $each
| if ($rows | length) < 2 or any($rows[]; .est == null) then $each
  else
    ($rows | group_by(.lane) | map(map(.left) | add) | max) as $all
    | "\($each) · all done in ~\($all | human)"
  end
