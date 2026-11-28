#!/usr/bin/env bash
# GPU の状態を nvidia-smi で読み、node_exporter のテキストファイル形式で書く。
# agent-env-gpu-metrics.timer が 30 秒ごとに実行する。bootstrap.sh が /usr/local/libexec/agent-env/ に配置する。
#   gpu-metrics.sh <出力するファイル>
set -euo pipefail

out="$1"
tmp="${out}.tmp"
# nvidia-smi の項目と、書き出す指標（名前、倍率、説明）。値が数値でない項目（[N/A] など）は書かない
fields=(
  "utilization.gpu gpu_utilization_percent 1 GPU utilization (percent)"
  "utilization.memory gpu_memory_bandwidth_utilization_percent 1 GPU memory bandwidth utilization (percent)"
  "memory.used gpu_memory_used_bytes 1048576 GPU memory used (bytes)"
  "memory.total gpu_memory_total_bytes 1048576 GPU memory total (bytes)"
  "power.draw gpu_power_watts 1 GPU power draw (watts)"
  "temperature.gpu gpu_temperature_celsius 1 GPU temperature (celsius)"
  "fan.speed gpu_fan_percent 1 GPU fan speed (percent)"
  "clocks.sm gpu_sm_clock_hz 1000000 GPU SM clock (hertz)"
)
query="index,name"
for f in "${fields[@]}"; do query+=",${f%% *}"; done

{
  if csv="$(nvidia-smi --query-gpu="${query}" --format=csv,noheader,nounits)"; then
    echo "# HELP gpu_up Whether nvidia-smi succeeded"
    echo "# TYPE gpu_up gauge"
    echo "gpu_up 1"
    printf '%s\n' "${fields[@]}" | awk -v csv="${csv}" '
      BEGIN { n = split(csv, rows, "\n") }
      {
        name = $2; scale = $3; help = $4
        for (i = 5; i <= NF; i++) help = help " " $i
        printf "# HELP %s %s\n# TYPE %s gauge\n", name, help, name
        for (r = 1; r <= n; r++) {
          split(rows[r], col, /, */)
          v = col[NR + 2]
          if (v ~ /^-?[0-9]+(\.[0-9]+)?$/) {
            gsub(/["\\]/, "", col[2])
            printf "%s{gpu=\"%s\",name=\"%s\"} %.15g\n", name, col[1], col[2], v * scale
          }
        }
      }'
  else
    echo "# HELP gpu_up Whether nvidia-smi succeeded"
    echo "# TYPE gpu_up gauge"
    echo "gpu_up 0"
  fi
} > "${tmp}"
chmod 0644 "${tmp}"
mv "${tmp}" "${out}"
