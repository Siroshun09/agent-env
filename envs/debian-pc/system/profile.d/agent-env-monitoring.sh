# shellcheck shell=sh
# bootstrap.sh が /etc/profile.d/ に配置する。
# Codex の指標を、この PC の監視（VictoriaMetrics）が扱いやすい累積方式で送る。Codex は設定ファイルではなく環境変数で指定する
export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative
