#!/usr/bin/env bash
set -Eeuo pipefail

ARCHIVE_URL="${ARCHIVE_URL:-https://github.com/giks89/test_assets/releases/download/npt/npt_nock.tar.gz}"
INSTALL_DIR="${INSTALL_DIR:-/opt/npt_nock}"
SESSION_NAME="${SESSION_NAME:-npt}"
CONFIG_NAME="${CONFIG_NAME:-config.json}"

req_pkgs=(ca-certificates curl jq screen)
export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating apt & installing deps: ${req_pkgs[*]}"
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends "${req_pkgs[@]}" >/dev/null

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

echo "[*] Downloading archive:"
echo "    $ARCHIVE_URL"
curl -fsSL --retry 5 --retry-delay 2 -o "$tmpdir/npt.tar.gz" "$ARCHIVE_URL"

echo "[*] Preparing install dir: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
# Распакуем во временный и потом найдём корень с бинарями
workdir="$tmpdir/unpack"
mkdir -p "$workdir"
tar -xzf "$tmpdir/npt.tar.gz" -C "$workdir"

# Найти папку, где лежит бинарь neptune
echo "[*] Locating binaries..."
BASE_DIR="$(find "$workdir" -type f -name 'neptune' -printf '%h\n' | head -n1 || true)"
if [[ -z "${BASE_DIR:-}" ]]; then
  echo "[ERROR] 'neptune' not found in archive!"
  exit 1
fi

echo "[*] Installing to: $INSTALL_DIR"
rm -rf "$INSTALL_DIR"/*
mkdir -p "$INSTALL_DIR"
cp -a "$BASE_DIR"/. "$INSTALL_DIR"/

cd "$INSTALL_DIR"

# Проверим, что оба бинаря есть
[[ -f ./neptune ]] || { echo "[ERROR] neptune not found after install"; exit 1; }
[[ -f ./golden-miner-pool-prover ]] || { echo "[ERROR] golden-miner-pool-prover not found after install"; exit 1; }

chmod +x ./neptune ./golden-miner-pool-prover

# Уникальное имя воркера
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
MACHINE_ID="$(cut -c1-6 /etc/machine-id 2>/dev/null || echo rnd$$)"
SERVER_NAME="${HOST_SHORT}-${MACHINE_ID}"

# Чиним config.json:
# 1) worker_name ← уникальное имя
# 2) абсолютный путь к golden-miner-pool-prover
# 3) подстановка %SERVER_NAME% в любых строковых полях
# 4) оставляем все флаги idle как есть (pubkey/name/threads), меняем только префикс команды
if [[ ! -f "$CONFIG_NAME" ]]; then
  echo "[ERROR] $CONFIG_NAME not found in $INSTALL_DIR"
  exit 1
fi

ABS_IDLE_BIN="$INSTALL_DIR/golden-miner-pool-prover"

# Правим JSON безопасно через jq
tmp_cfg="$tmpdir/config.json"
jq --arg name "$SERVER_NAME" --arg idle "$ABS_IDLE_BIN" '
  # 1) worker_name у главного алгоритма
  (.algo_list[0].worker_name) = $name
  |
  # 2) подстановка %SERVER_NAME% по всему дереву
  (.. | scalars) |= (if type=="string" then gsub("%SERVER_NAME%"; $name) else . end)
  |
  # 3) заменить только путь в команде idle, флаги сохранить
  (.algo_list |= (map(
    if .id=="my-idle-command" and (.command|type)=="string" then
      (.command | split(" ")) as $p
      | .command =
          ( if ($p|length)>0
            then ($idle + ( if ($p|length)>1 then " " + ($p[1:]|join(" ")) else "" end))
            else $idle
            end )
    else .
    end
  )))
' "$CONFIG_NAME" > "$tmp_cfg"
mv "$tmp_cfg" "$CONFIG_NAME"

echo "[*] Final config.json:"
jq '.selected, .algo_list[0].worker_name, (.algo_list[]|select(.id=="my-idle-command")|.command)' "$CONFIG_NAME" | sed 's/^/    /'

# Старт в screen (detached), с логом
LOG_FILE="$INSTALL_DIR/neptune.log"
echo "[*] Starting miner in screen session: $SESSION_NAME"
# Закроем прошлую сессию, если есть
screen -S "$SESSION_NAME" -X quit || true
# Стартуем
screen -DmS "$SESSION_NAME" bash -lc "cd '$INSTALL_DIR'; exec ./neptune run --config '$INSTALL_DIR/$CONFIG_NAME' 2>&1 | tee -a '$LOG_FILE'"

echo
echo "[OK] Launched. Attach:  screen -r $SESSION_NAME"
echo "     Log:      tail -f '$LOG_FILE'"
echo "     Stop:     screen -S $SESSION_NAME -X quit"


