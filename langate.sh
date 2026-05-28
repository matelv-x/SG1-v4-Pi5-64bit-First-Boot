#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/home/pi/sg1_v4}"
ADDRESS_FILE="${ADDRESS_FILE:-$APP_DIR/config/milkyway-addresses.json}"
PORTS="${PORTS:-8080 80}"
TIMEOUT="${TIMEOUT:-0.6}"
MAX_WORKERS="${MAX_WORKERS:-64}"
RESTART_SERVICE=1
PATCH_APP=1
ORIGINAL_ARGS=("$@")

usage() {
    cat <<'EOF'
Usage:
  ./langate.sh [--no-restart] [--scan-only]

This patch gives the original SG1 v4 image LAN-gate support:
  - adds/repairs lan_gates support in the app code
  - shows LAN Gates in Address Book summary/list
  - makes LAN gates win over Fan/Subspace gates when dialing
  - scans the local /24 network and writes found gates to lan_gates

Environment overrides:
  APP_DIR=/home/pi/sg1_v4
  ADDRESS_FILE=/home/pi/sg1_v4/config/milkyway-addresses.json
  PORTS="8080 80"
  TIMEOUT=0.6
  MAX_WORKERS=64
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-restart)
            RESTART_SERVICE=0
            shift
            ;;
        --scan-only)
            PATCH_APP=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ ! -d "$APP_DIR" ]; then
    echo "SG1 app directory not found: $APP_DIR" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ] && [ -e "$ADDRESS_FILE" ] && [ ! -w "$ADDRESS_FILE" ]; then
    exec sudo env \
        APP_DIR="$APP_DIR" \
        ADDRESS_FILE="$ADDRESS_FILE" \
        PORTS="$PORTS" \
        TIMEOUT="$TIMEOUT" \
        MAX_WORKERS="$MAX_WORKERS" \
        PYTHON_BIN="${PYTHON_BIN:-}" \
        bash "$0" "${ORIGINAL_ARGS[@]}"
fi

PYTHON_BIN="${PYTHON_BIN:-}"
if [ -z "$PYTHON_BIN" ]; then
    if [ -x /home/pi/venv_v4/bin/python ]; then
        PYTHON_BIN=/home/pi/venv_v4/bin/python
    else
        PYTHON_BIN=python3
    fi
fi

export APP_DIR ADDRESS_FILE PORTS TIMEOUT MAX_WORKERS PATCH_APP

"$PYTHON_BIN" - <<'PY'
#!/usr/bin/env python3
import json
import os
import py_compile
import re
import shutil
import socket
import subprocess
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from ipaddress import ip_network
from pathlib import Path

APP_DIR = Path(os.environ["APP_DIR"])
ADDRESS_FILE = Path(os.environ["ADDRESS_FILE"])
APP_CONFIG_FILE = APP_DIR / "config" / "milkyway-config.json"
PORTS = [int(port) for port in os.environ.get("PORTS", "8080 80").split()]
TIMEOUT = float(os.environ.get("TIMEOUT", "0.6"))
MAX_WORKERS = int(os.environ.get("MAX_WORKERS", "64"))
PATCH_APP = os.environ.get("PATCH_APP", "1") == "1"
STAMP = time.strftime("%Y%m%d-%H%M%S")
ENDPOINTS = (
    "/get/system_info",
    "/stargate/get/system_info",
    "/get/is_alive",
    "/stargate/get/is_alive",
)


def read_text(path):
    return path.read_text(encoding="utf-8")


def write_text_if_changed(path, text):
    old = path.read_text(encoding="utf-8") if path.exists() else ""
    if old == text:
        return False
    backup = path.with_suffix(path.suffix + f".bak-langate-{STAMP}")
    if path.exists():
        shutil.copy2(path, backup)
        print(f"Backup: {backup}")
    path.write_text(text, encoding="utf-8")
    print(f"Patched: {path}")
    return True


def replace_function(text, name, new_body):
    pattern = re.compile(rf"(?ms)^    def {re.escape(name)}\(.*?(?=^    def |^class |\Z)")
    if not pattern.search(text):
        return text, False
    return pattern.sub(new_body.rstrip() + "\n\n", text, count=1), True


def insert_before_function(text, name, block):
    marker = f"    def {name}("
    if marker not in text:
        return text, False
    return text.replace(marker, block.rstrip() + "\n\n" + marker, 1), True


def ensure_address_config():
    if not ADDRESS_FILE.exists():
        defaults = APP_DIR / "config" / "defaults-milkyway" / "addresses.json.dist"
        if defaults.exists():
            ADDRESS_FILE.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(defaults, ADDRESS_FILE)
        else:
            raise SystemExit(f"Address file not found: {ADDRESS_FILE}")

    config = json.loads(ADDRESS_FILE.read_text(encoding="utf-8"))
    if "lan_gates" not in config:
        config["lan_gates"] = {
            "value": {},
            "desc": "A Dictionary of LAN Gates. These allow inter-Stargate communication without an internet connection, or Subspace Network configuration.",
            "type": "dict",
        }
        backup = ADDRESS_FILE.with_suffix(ADDRESS_FILE.suffix + f".bak-langate-{STAMP}")
        shutil.copy2(ADDRESS_FILE, backup)
        ADDRESS_FILE.write_text(json.dumps(config, indent=4), encoding="utf-8")
        print(f"Added lan_gates config: {ADDRESS_FILE}")
        print(f"Backup: {backup}")


def patch_address_book():
    path = APP_DIR / "classes" / "stargate_address_book.py"
    text = read_text(path)

    if 'self.datastore.set("lan_gates", {})' not in text:
        text = text.replace(
            '        self.datastore.set("fan_gates", {})\n        self.datastore.set("standard_gates", {})',
            '        self.datastore.set("fan_gates", {})\n        self.datastore.set("lan_gates", {})\n        self.datastore.set("standard_gates", {})',
        )

    get_entry = '''    def get_entry_by_address(self, address):
        #print("Searching Address Book for {}".format(address))

        found_standard_gate = self.get_standard_gate_by_address(address)
        if found_standard_gate:
            found_standard_gate['type'] = 'standard'
            return found_standard_gate

        found_lan_gate = self.get_lan_gate_by_address(address)
        if found_lan_gate:
            found_lan_gate['type'] = 'lan'
            return found_lan_gate

        found_fan_gate = self.get_fan_gate_by_address(address)
        if found_fan_gate:
            found_fan_gate['type'] = 'fan'
            return found_fan_gate

        return False'''
    text, _ = replace_function(text, "get_entry_by_address", get_entry)

    all_nonlocal = '''    def get_all_nonlocal_addresses(self):
        fan_gates = self.get_fan_gates()
        lan_gates = self.get_lan_gates()
        standard_gates = self.get_standard_gates()
        all_gates = {**fan_gates, **lan_gates, **standard_gates}
        return all_gates'''
    text, _ = replace_function(text, "get_all_nonlocal_addresses", all_nonlocal)

    fan_and_lan = '''    def get_fan_and_lan_addresses(self):
        fan_gates = self.get_fan_gates()
        lan_gates = self.get_lan_gates()
        all_gates = {**fan_gates, **lan_gates}
        return all_gates'''
    if "def get_fan_and_lan_addresses" in text:
        text, _ = replace_function(text, "get_fan_and_lan_addresses", fan_and_lan)
    else:
        text, _ = insert_before_function(text, "get_fan_gates", fan_and_lan)

    lan_block = '''# ----

    def get_lan_gates(self):
        gates = self.datastore.get("lan_gates").copy()
        for record in gates.values():
            record['type'] = 'lan'
        return gates

    def get_lan_gate_by_address(self, address):
        for value in self.get_lan_gates().values():
            if address == value['gate_address']:
                return value

        return False

    def set_lan_gate(self, name, gate_address, ip_address, is_black_hole=False, is_gate_online="1"):
        lan_gates = self.get_lan_gates()
        for existing_name, existing_gate in list(lan_gates.items()):
            if existing_name == name:
                continue
            if (
                existing_gate.get("gate_address") == gate_address
                or existing_gate.get("ip_address") == ip_address
            ):
                lan_gates.pop(existing_name, None)
        lan_gates[name] = {
            "name": name,
            "gate_address": gate_address,
            "ip_address": ip_address,
            "is_gate_online": is_gate_online,
            "is_black_hole": is_black_hole,
            "type": "lan",
        }
        self.datastore.set("lan_gates", lan_gates)'''
    if "def get_lan_gates" in text:
        text, _ = replace_function(text, "get_lan_gates", lan_block.split("\n\n", 1)[1].split("\n\n    def get_lan_gate_by_address", 1)[0])
        text, _ = replace_function(text, "get_lan_gate_by_address", "    def get_lan_gate_by_address" + lan_block.split("    def get_lan_gate_by_address", 1)[1].split("\n\n    def set_lan_gate", 1)[0])
        text, _ = replace_function(text, "set_lan_gate", "    def set_lan_gate" + lan_block.split("    def set_lan_gate", 1)[1])
    else:
        text, _ = insert_before_function(text, "get_standard_gates", lan_block)

    return write_text_if_changed(path, text)


def patch_address_manager():
    path = APP_DIR / "classes" / "stargate_address_manager.py"
    text = read_text(path)

    if "from concurrent.futures import ThreadPoolExecutor, as_completed" not in text:
        text = text.replace("from ast import literal_eval\n", "from ast import literal_eval\nfrom concurrent.futures import ThreadPoolExecutor, as_completed\n")
    if "from ipaddress import ip_network" not in text:
        text = text.replace("from datetime import datetime\n", "from datetime import datetime\nfrom ipaddress import ip_network\n")
    if "from threading import Thread" not in text:
        text = text.replace("import json\n", "import json\nfrom threading import Thread\n")

    if "self.lan_discovery_interval" not in text:
        marker = "            stargate.app.schedule.every(update_interval).minutes.do( self.update_fan_gates_from_api )"
        if marker in text:
            text = text.replace(
                marker,
                marker + "\n\n        self.lan_discovery_interval = 5\n        stargate.app.schedule.every(self.lan_discovery_interval).minutes.do(self.start_lan_gate_discovery)\n        self.start_lan_gate_discovery()",
            )
        else:
            marker = "        self.info_api_url = self.cfg.get(\"subspace_public_api_url\")"
            text = text.replace(
                marker,
                marker + "\n\n        self.lan_discovery_interval = 5\n        stargate.app.schedule.every(self.lan_discovery_interval).minutes.do(self.start_lan_gate_discovery)\n        self.start_lan_gate_discovery()",
            )

    discovery_block = '''    def start_lan_gate_discovery(self):
        discovery_thread = Thread(target=self.update_lan_gates_from_network, daemon=True)
        discovery_thread.start()

    def update_lan_gates_from_network(self):
        local_ip = self.net_tools.get_ip_by_interface_list(['wlan0', 'eth0', 'en0', 'en1'])
        if not local_ip:
            self.log.log("LAN Gate Discovery: no LAN IP found")
            return {}

        try:
            network = ip_network(f"{local_ip}/24", strict=False)
        except ValueError as exc:
            self.log.log(f"LAN Gate Discovery: invalid local network for {local_ip}: {exc}")
            return {}

        port = self.cfg.get("control_api_server_port")
        found = {}
        hosts = [str(host) for host in network.hosts() if str(host) != local_ip]

        self.log.log(f"LAN Gate Discovery: scanning {network} on port {port}")
        with ThreadPoolExecutor(max_workers=32) as executor:
            future_to_ip = {
                executor.submit(self._probe_lan_stargate, ip_addr, port): ip_addr
                for ip_addr in hosts
            }
            for future in as_completed(future_to_ip):
                gate = future.result()
                if not gate:
                    continue

                name = gate["name"]
                found[name] = gate
                self.address_book.set_lan_gate(
                    name,
                    gate["gate_address"],
                    gate["ip_address"],
                    gate["is_black_hole"],
                )

        if found:
            self.log.log(f"LAN Gate Discovery: found {len(found)} gate(s): {', '.join(sorted(found.keys()))}")
        else:
            self.log.log("LAN Gate Discovery: no local gates found")

        return found

    def _probe_lan_stargate(self, ip_addr, port):
        url = f"http://{ip_addr}:{port}/get/system_info"
        try:
            response = requests.get(url, timeout=2.0)
            if response.status_code != 200:
                return None
            data = response.json()
        except (requests.RequestException, ValueError, json.JSONDecodeError):
            return None

        gate_address = data.get("local_stargate_address")
        if not isinstance(gate_address, list) or not 6 <= len(gate_address) <= 9:
            return None
        if gate_address == self.address_book.get_local_address():
            return None

        gate_name = data.get("gate_name") or f"Stargate {ip_addr}"
        return {
            "name": str(gate_name),
            "gate_address": gate_address,
            "ip_address": ip_addr,
            "is_gate_online": "1",
            "is_black_hole": False,
            "type": "lan",
        }'''
    if "def start_lan_gate_discovery" not in text:
        text, _ = insert_before_function(text, "valid_planet", discovery_block)

    get_ip = '''    def get_ip_from_stargate_address(self, stargate_address):
        """
        Return the IP address for a dialed Stargate address. LAN gates are
        checked before Fan/Subspace gates so local dialing works without
        Internet/Subspace and does not get overridden by public records.
        """
        if len(stargate_address) > 1:
            for stargate_config in self.address_book.get_lan_gates().values():
                if stargate_address[0:2] == stargate_config['gate_address'][0:2]:
                    return stargate_config['ip_address']

            for stargate_config in self.address_book.get_fan_gates().values():
                if stargate_address[0:2] == stargate_config['gate_address'][0:2]:
                    return stargate_config['ip_address']

        self.log.log( f'Unable to get IP for {stargate_address}')
        return None'''
    text, _ = replace_function(text, "get_ip_from_stargate_address", get_ip)

    return write_text_if_changed(path, text)


def patch_web_server():
    path = APP_DIR / "classes" / "web_server.py"
    text = read_text(path)

    if "lan_gate_count" not in text and '"fan_gate_count"' in text:
        text = text.replace(
            '                    "fan_gate_count":                 len(self.stargate.addr_manager.get_book().get_fan_gates()),',
            '                    "fan_gate_count":                 len(self.stargate.addr_manager.get_book().get_fan_gates()),\n                    "lan_gate_count":                 len(self.stargate.addr_manager.get_book().get_lan_gates()),',
        )

    if "get_fan_and_lan_addresses" not in text:
        text = text.replace(
            "data['address_book'] = self.stargate.addr_manager.get_book().get_fan_gates()",
            "data['address_book'] = self.stargate.addr_manager.get_book().get_fan_and_lan_addresses()",
        )

    return write_text_if_changed(path, text)


def patch_address_book_js():
    path = APP_DIR / "web" / "js" / "address_book.js"
    text = read_text(path)
    if '"lan": "LAN Gates"' not in text:
        text = text.replace(
            '      "fan": "Subspace Gates",\n      "standard": "Standard Gates",',
            '      "fan": "Subspace Gates",\n      "lan": "LAN Gates",\n      "standard": "Standard Gates",',
        )
    return write_text_if_changed(path, text)


def patch_app():
    ensure_address_config()
    changed = False
    changed |= patch_address_book()
    changed |= patch_address_manager()
    changed |= patch_web_server()
    changed |= patch_address_book_js()

    for path in (
        APP_DIR / "classes" / "stargate_address_book.py",
        APP_DIR / "classes" / "stargate_address_manager.py",
        APP_DIR / "classes" / "web_server.py",
    ):
        py_compile.compile(str(path), cfile=f"/tmp/{path.name}.langate.pyc", doraise=True)

    if changed:
        print("LAN application patch: applied")
    else:
        print("LAN application patch: already present")


def get_lan_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except OSError:
        pass

    try:
        output = subprocess.check_output(["hostname", "-I"], text=True, stderr=subprocess.DEVNULL)
        for part in output.split():
            if "." in part and not part.startswith("127."):
                return part
    except Exception:
        pass

    return None


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "SG1-LAN-Gate-Scanner"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
        raw = response.read().decode("utf-8", errors="ignore")
    return json.loads(raw)


def normalize_address(address):
    if isinstance(address, list):
        return address
    if isinstance(address, str):
        try:
            parsed = json.loads(address)
            if isinstance(parsed, list):
                return parsed
        except Exception:
            return []
    return []


def get_field(data, names):
    if not isinstance(data, dict):
        return None
    for name in names:
        if name in data:
            return data[name]
    return None


def probe(ip_addr):
    for port in PORTS:
        for endpoint in ENDPOINTS:
            url = f"http://{ip_addr}:{port}{endpoint}"
            try:
                data = fetch_json(url)
            except Exception:
                continue

            name = get_field(data, ("gate_name", "name", "hostname", "host"))
            address = normalize_address(get_field(
                data,
                ("local_stargate_address", "local_gate_address", "gate_address", "address"),
            ))

            if not 6 <= len(address) <= 9:
                continue

            return {
                "name": str(name or f"Stargate {ip_addr}"),
                "gate_address": address,
                "ip_address": ip_addr,
                "is_gate_online": "1",
                "is_black_hole": False,
                "type": "lan",
            }

    return None


def load_address_file(path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_app_config():
    if not APP_CONFIG_FILE.exists():
        return {}
    with APP_CONFIG_FILE.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def get_config_value(config, key, default):
    field = config.get(key)
    if isinstance(field, dict) and "value" in field:
        return field["value"]
    return default


def set_config_value(config, key, value):
    field = config.get(key)
    if isinstance(field, dict):
        field["value"] = value
    else:
        config[key] = {
            "value": value,
            "desc": "A Dictionary of LAN Gates.",
            "type": "dict",
        }


def has_subspace_config(app_config):
    configured_ip = get_config_value(app_config, "subspace_ip_address", "")
    return bool(configured_ip)


def fan_gate_exists_for_local_address(config, local_address):
    fan_gates = get_config_value(config, "fan_gates", {})
    if not isinstance(fan_gates, dict):
        return False
    return any(gate.get("gate_address") == local_address for gate in fan_gates.values())


def remove_local_address_from_section(config, section_name, local_address):
    gates = get_config_value(config, section_name, {})
    if not isinstance(gates, dict):
        return False

    changed = False
    for name, gate in list(gates.items()):
        if gate.get("gate_address") == local_address or gate.get("is_local_gate"):
            gates.pop(name, None)
            changed = True

    if changed:
        set_config_value(config, section_name, gates)
    return changed


def get_local_gate_name(local_address):
    fallback_name = "Seed Ship#1" if local_address == [3, 7, 11, 19, 22, 30, 34, 36] else "stargate"
    generic_names = {"", "stargate", "raspberrypi", "gate3"}
    for port in PORTS:
        for endpoint in ("/get/system_info", "/stargate/get/system_info"):
            try:
                data = fetch_json(f"http://127.0.0.1:{port}{endpoint}")
            except Exception:
                continue
            if normalize_address(data.get("local_stargate_address")) == local_address:
                gate_name = str(data.get("gate_name") or "").strip()
                if gate_name.lower() not in generic_names:
                    return gate_name
                return fallback_name
    return fallback_name


def sync_local_lan_gate(config, lan_gates, local_address, local_ip):
    if not local_address:
        return False

    app_config = load_app_config()
    subspace_configured = has_subspace_config(app_config)
    changed = False

    if subspace_configured and fan_gate_exists_for_local_address(config, local_address):
        for name, gate in list(lan_gates.items()):
            if gate.get("gate_address") == local_address or gate.get("is_local_gate"):
                lan_gates.pop(name, None)
                changed = True
                print(f"- Removed local LAN duplicate after Subspace registration: {name}")
        return changed

    if subspace_configured:
        return False

    changed |= remove_local_address_from_section(config, "fan_gates", local_address)
    changed |= remove_local_address_from_section(config, "standard_gates", local_address)

    local_name = get_local_gate_name(local_address)
    for name, gate in list(lan_gates.items()):
        if name == local_name:
            continue
        if gate.get("gate_address") == local_address or gate.get("is_local_gate"):
            lan_gates.pop(name, None)
            changed = True

    local_entry = {
        "name": local_name,
        "gate_address": local_address,
        "ip_address": local_ip,
        "is_gate_online": "1",
        "is_black_hole": False,
        "type": "lan",
        "is_local_gate": True,
    }
    if lan_gates.get(local_name) != local_entry:
        lan_gates[local_name] = local_entry
        changed = True
        print(f"- Local LAN gate: {local_name} | {local_ip} | {local_address}")

    return changed


def same_gate(existing, new):
    return (
        existing.get("name") == new.get("name")
        or existing.get("gate_address") == new.get("gate_address")
        or existing.get("ip_address") == new.get("ip_address")
    )


def save_lan_gates(config, lan_gates):
    backup = ADDRESS_FILE.with_suffix(ADDRESS_FILE.suffix + f".bak-langate-{STAMP}")
    shutil.copy2(ADDRESS_FILE, backup)
    set_config_value(config, "lan_gates", lan_gates)
    ADDRESS_FILE.write_text(json.dumps(config, indent=4), encoding="utf-8")

    print()
    print(f"Saved: {ADDRESS_FILE}")
    print(f"Backup: {backup}")
    print(f"LAN gates in address book: {len(lan_gates)}")


def scan_and_update():
    local_ip = get_lan_ip()
    if not local_ip:
        raise SystemExit("No LAN IP found.")

    network = ip_network(f"{local_ip}/24", strict=False)
    hosts = [str(host) for host in network.hosts() if str(host) != local_ip]

    print(f"Scanning {network} from {local_ip} on ports: {', '.join(map(str, PORTS))}")

    found = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = [executor.submit(probe, host) for host in hosts]
        for future in as_completed(futures):
            gate = future.result()
            if gate:
                found.append(gate)

    config = load_address_file(ADDRESS_FILE)
    local_address = get_config_value(config, "local_stargate_address", [])
    lan_gates = get_config_value(config, "lan_gates", {})
    if not isinstance(lan_gates, dict):
        lan_gates = {}
    changed = sync_local_lan_gate(config, lan_gates, local_address, local_ip)

    if not found:
        print("No LAN Stargates found.")
        for name, gate in lan_gates.items():
            if gate.get("is_local_gate"):
                continue
            if gate.get("is_gate_online") != "0":
                gate["is_gate_online"] = "0"
                changed = True
                print(f"- Offline: {name} | {gate.get('ip_address', 'unknown')}")
        if changed:
            save_lan_gates(config, lan_gates)
            return
        print(f"LAN gates in address book: {len(lan_gates)}")
        return

    online_names = set()
    print()
    print("Found LAN gates:")

    for gate in sorted(found, key=lambda item: (item["name"], item["ip_address"])):
        if gate["gate_address"] == local_address:
            continue

        for existing_name, existing in list(lan_gates.items()):
            if existing_name == gate["name"]:
                continue
            if same_gate(existing, gate):
                lan_gates.pop(existing_name, None)

        previous = lan_gates.get(gate["name"])
        if previous != gate:
            lan_gates[gate["name"]] = gate
            changed = True
            action = "Updated" if previous else "Added"
        else:
            action = "Unchanged"

        online_names.add(gate["name"])
        print(f"- {action}: {gate['name']} | {gate['ip_address']} | {gate['gate_address']}")

    for name, gate in lan_gates.items():
        if name in online_names:
            continue
        if gate.get("is_local_gate"):
            continue
        if gate.get("is_gate_online") != "0":
            gate["is_gate_online"] = "0"
            changed = True
            print(f"- Offline: {name} | {gate.get('ip_address', 'unknown')}")

    if not changed:
        print()
        print("No address-book changes needed.")
        print(f"LAN gates in address book: {len(lan_gates)}")
        return

    save_lan_gates(config, lan_gates)


def main():
    if PATCH_APP:
        patch_app()
    else:
        ensure_address_config()
    scan_and_update()


if __name__ == "__main__":
    main()
PY

if [ "$RESTART_SERVICE" = "1" ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files stargate.service >/dev/null 2>&1; then
        echo
        echo "Restarting stargate.service"
        if [ "$(id -u)" -eq 0 ]; then
            systemctl restart stargate.service
        else
            sudo systemctl restart stargate.service
        fi
    fi
fi

echo
echo "DONE."
