# shellcheck shell=sh
# bootstrap.sh が /etc/profile.d/ に配置する。
# mise で入れたツールを、ログインシェル以外（エージェントが実行するコマンドなど）からも使えるように shims を PATH に入れる。
case ":${PATH}:" in
  *":${HOME}/.local/share/mise/shims:"*) ;;
  *) PATH="${HOME}/.local/share/mise/shims:${PATH}" ;;
esac
