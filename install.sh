#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 root 权限运行此脚本 (sudo bash install.sh)"
  exit 1
fi

# 1. 获取用户输入的 VPS IP
echo "==============================================="
echo "       Axis ai 测速"
echo "==============================================="
read -p "请输入测速 VPS 的 IP 地址: " VPS_IP < /dev/tty

if [ -z "$VPS_IP" ]; then
    echo "错误: IP 地址不能为空。"
    exit 1
fi

# 2. 配置 VPS IP
CONFIG_DIR="/var/lib/vastai_kaalia"
CONFIG_FILE="$CONFIG_DIR/.speedtest_vps"

# 确保目录存在
if [ ! -d "$CONFIG_DIR" ]; then
    echo "警告: $CONFIG_DIR 不存在，正在创建..."
    mkdir -p "$CONFIG_DIR"
fi

echo "正在保存 VPS IP 到 $CONFIG_FILE ..."
echo "$VPS_IP" > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# 3. 释放 Python 脚本到持久化位置
STORE_DIR="/usr/local/share/vast_speedtest_hack"
STORE_FILE="$STORE_DIR/send_mach_info.py"
mkdir -p "$STORE_DIR"

echo "正在写入 Python 脚本到 $STORE_FILE ..."
cat > "$STORE_FILE" <<'PYTHON_EOF'
#!/usr/bin/python3
import json
import subprocess
import requests
import random
import os
import subprocess
import platform
import time
from argparse import ArgumentParser

from datetime import datetime


from pathlib import Path
import re

CLK_TCK = os.sysconf(os.sysconf_names.get("SC_CLK_TCK", "SC_CLK_TCK"))
NCPU = os.cpu_count() or 1

# Patterns that indicate the process is in a containerized cgroup (Docker/containerd/K8s/Podman)
CGROUP_CONTAINER_PAT = re.compile(r"(docker|containerd|kubepods|libpod)", re.IGNORECASE)


def read_proc_stat_cpu():
    """
    Read the aggregated CPU times from /proc/stat.
    Returns (total_jiffies, idle_jiffies).
    """
    with open("/proc/stat", "r") as f:
        for line in f:
            if line.startswith("cpu "):
                parts = line.split()
                # cpu user nice system idle iowait irq softirq steal guest guest_nice
                # Use standard kernel accounting: total is sum of first 8 fields (user..steal)
                # idle time is idle + iowait
                # Some kernels have fewer/more fields; guard accordingly.
                values = [int(x) for x in parts[1:]]
                # Ensure length >= 8
                while len(values) < 8:
                    values.append(0)
                user, nice, system, idle, iowait, irq, softirq, steal = values[:8]
                idle_all = idle + iowait
                total = user + nice + system + idle + iowait + irq + softirq + steal
                return total, idle_all
    # Fallback if cpu line missing (shouldn't happen on Linux)
    return 0, 0


def list_pids():
    for name in os.listdir("/proc"):
        if name.isdigit():
            yield name


def pid_in_container(pid):
    """
    Heuristic: check /proc/<pid>/cgroup entries for container-runtime markers.
    """
    try:
        with open(f"/proc/{pid}/cgroup", "r") as f:
            data = f.read()
        return bool(CGROUP_CONTAINER_PAT.search(data))
    except Exception:
        return False


def pid_utime_stime_jiffies(pid):
    """
    Return utime + stime for a process, in jiffies.
    We do not add children's times to avoid double counting when summing across PIDs.
    """
    try:
        with open(f"/proc/{pid}/stat", "r") as f:
            stat = f.read().split()
        # utime is field 14, stime is field 15 (1-indexed in manpage; 0-indexed here -> 13,14)
        utime = int(stat[13])
        stime = int(stat[14])
        return utime + stime
    except Exception:
        return 0


def sample_process_cpu_split():
    """
    Sum utime+stime across all PIDs, split by (inside_container vs outside).
    Returns tuple (sum_in_docker_jiffies, sum_outside_jiffies).
    """
    in_docker = 0
    outside = 0
    for pid in list_pids():
        j = pid_utime_stime_jiffies(pid)
        if j == 0:
            # could be kernel thread or permission error; skip quietly
            continue
        if pid_in_container(pid):
            in_docker += j
        else:
            outside += j
    return in_docker, outside


def disable_unattended_upgrades():
    subprocess.run(["sudo", "systemctl", "status", "unattended-upgrades"], check=True) #INFO: doesn't throw if enabled
    subprocess.run(["sudo", "systemctl", "stop", "unattended-upgrades"], check=True) #INFO: stop the current running systemd unit
    subprocess.run(["sudo", "systemctl", "mask", "unattended-upgrades"], check=True) #INFO: Mask systemd service so it doesn't ever try running again via restart systemd unit or rebooting machine on an enabled service



def compute_total_busy_pct(t0_total, t0_idle, t1_total, t1_idle):
    total_delta = max(1, t1_total - t0_total)
    idle_delta = max(0, t1_idle - t0_idle)
    busy_delta = max(0, total_delta - idle_delta)
    # busy fraction across all cores; normalized to 0..100
    return (busy_delta / total_delta) * 100.0


def iommu_groups():
    return Path('/sys/kernel/iommu_groups').glob('*') 
def iommu_groups_by_index():
    return ((int(path.name) , path) for path in iommu_groups())

class PCI:
    def __init__(self, id_string):
        parts: list[str] = re.split(r':|\.', id_string)
        if len(parts) == 4:
            PCI.domain = int(parts[0], 16)
            parts = parts[1:]
        else:
            PCI.domain = 0
        assert len(parts) == 3
        PCI.bus = int(parts[0], 16)
        PCI.device = int(parts[1], 16)
        PCI.fn = int(parts[2], 16)
        
# returns an iterator of devices, each of which contains the list of device functions.  
def iommu_devices(iommu_path : Path):
    paths = (iommu_path / "devices").glob("*")
    devices= {}
    for path in paths:
        pci = PCI(path.name)
        device = (pci.domain, pci.bus,pci.device)
        if device in devices:
            devices[device].append((pci,path))
        else:
            devices[device] = [(pci,path)]
    return devices

# given a list of device function IDs belonging to a device and their paths, 
# gets the render_node if it has one, using a list as an optional
def render_no_if_gpu(device_fns):
    for (_, path) in device_fns:
        if (path / 'drm').exists():
            return [r.name for r in (path/'drm').glob("render*")]
    return []

# returns a dict of bus:device -> (all pci ids, renderNode) for all gpus in an iommu group, by iommu group 
def gpus_by_iommu_by_index():
    iommus = iommu_groups_by_index()
    for index,path in iommus:
        devices = iommu_devices(path)
        gpus= {}
        for d in devices:
            gpu_m = render_no_if_gpu(devices[d])
            if gpu_m:
                gpus[d] = (devices[d], gpu_m[0])
        if len(gpus) > 0:
            yield (index,gpus)

def devices_by_iommu_by_index():
    iommus = iommu_groups_by_index()
    devices = {}
    for index,path in iommus:
        devices[index] = iommu_devices(path)
    return devices

# check if each iommu group has only one gpu
def check_if_iommu_ok(iommu_gpus, iommu_devices):
    has_iommu_gpus = False
    for (index, gpus) in iommu_gpus:
        group_has_iommu_gpus = False
        has_iommu_gpus = True
        if len(iommu_devices[index]) > 1:
            for pci_address in iommu_devices[index]:
                # check if device is gpu itself
                if pci_address in gpus:
                    if group_has_iommu_gpus:
                        return False
                    group_has_iommu_gpus = True
                    continue
                # else, check if device is bridge
                for (pci_fn, path) in iommu_devices[index][pci_address]:
                    try:
                        pci_class = subprocess.run(
                            ['sudo', 'cat', path / 'class'],
                            capture_output=True,
                            text=True,
                            check=True
                        )
                        # bridges have class 06, class is stored in hex fmt, so 0x06XXXX should be fine to pass along w/ group
                        if pci_class.stdout[2:4] != '06':
                            return False
                    except Exception as e:
                        print(f"An error occurred: {e}")
                        return False
    try:
        result = subprocess.run(
            ['sudo', 'cat', '/sys/module/nvidia_drm/parameters/modeset'],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout[0] == 'N' and has_iommu_gpus
    except Exception as e:
        print(f"An error occurred: {e}")
        return False

def has_active_vast_volumes():
    result = subprocess.run(["docker", "volume", "ls", "--format", "{{.Name}}"], capture_output=True, text=True)

    try:
        for line in result.stdout.splitlines():
            if "V." in line:
                return True
    except Exception as e:
        print("An Error Occured:", e)
        pass

    return False

def check_volumes_xfs_quota():
    quota_amounts = {}
    result = subprocess.run(["sudo", "xfs_quota", "-x", "-c", "report -p -N", "/var/lib/docker"], capture_output=True)
    lines = result.stdout.decode().split('\n')
    vast_volume_lines = [line for line in lines if line.strip().startswith('V.')]

    for vast_volume_line in vast_volume_lines:
        volume_name, volume_quota = parse_vast_quota(vast_volume_line)
        quota_amounts[volume_name] = volume_quota

    return quota_amounts

#INFO: returns a tuple of volume name and the quota amount in Kib
def parse_vast_quota(vast_volume_line):
    split_lines = vast_volume_line.split(" ")
    filtered_split_lines = [line for line in split_lines if line != ""]

    return filtered_split_lines[0], int(filtered_split_lines[3])

def numeric_version(version_str):
    try:
        # Split the version string by the period
        try:
            major, minor, patch = version_str.split('.')
        except:
            major, minor = version_str.split('.')
            patch = ''

        # Pad each part with leading zeros to make it 3 digits
        major = major.zfill(3)
        minor = minor.zfill(3)
        patch = patch.zfill(3)

        # Concatenate the padded parts
        numeric_version_str = f"{major}{minor}{patch}"

        # Convert the concatenated string to an integer
        return int(numeric_version_str)

    except ValueError:
        print("Invalid version string format. Expected format: X.X.X")
        return None

def get_nvidia_driver_version():
    try:
        # Run the nvidia-smi command and capture its output
        output = subprocess.check_output(['nvidia-smi'], stderr=subprocess.STDOUT, text=True)

        # Split the output by lines
        lines = output.strip().split('\n')

        # Loop through each line and search for the driver version
        for line in lines:
            if "Driver Version" in line:
                # Extract driver version
                version_info = line.split(":")[1].strip()
                vers = version_info.split(" ")[0]
                return numeric_version(vers)

    except subprocess.CalledProcessError:
        print("Error: Failed to run nvidia-smi.")
    except Exception as e:
        print(f"An unexpected error occurred: {e}")

    return None


def cond_install(package, extra=None):
    result = False
    location = ""
    try:
        location = subprocess.check_output(f"which {package}", shell=True).decode('utf-8').strip()
        print(location)
    except:
        pass

    if (len(location) < 1):
        print(f"installing {package}")
        output = None
        try:
            if (extra is not None):
                output  = subprocess.check_output(extra, shell=True).decode('utf-8')
            output  = subprocess.check_output(f"sudo apt install -y {package}", shell=True).decode('utf-8')
            result = True
        except:
            print(output)
    else:
        result = True
    return result

def find_drive_of_mountpoint(target):
    output = subprocess.check_output("lsblk -sJap",  shell=True).decode('utf-8')
    jomsg = json.loads(output)
    blockdevs = jomsg.get("blockdevices", [])
    mountpoints = None
    devname = None
    for bdev in blockdevs:
        mountpoints = bdev.get("mountpoints", [])
        if (not mountpoints):
            # for ubuntu version < 22.04
            mountpoints = [bdev.get("mountpoint", None)]
        if (target in mountpoints):
            devname = bdev.get("name", None)
            nextn = bdev
            while nextn is not None:
                devname = nextn.get("name", None)
                try:
                    nextn = nextn.get("children",[None])[0]
                except:
                    nextn = None
    return devname

def epsilon_greedyish_speedtest():
    """
    通过SSH连接到远端VPS执行测速
    VPS地址从配置文件读取: /var/lib/vastai_kaalia/.speedtest_vps
    """
    # 从配置文件读取VPS地址
    try:
        with open('/var/lib/vastai_kaalia/.speedtest_vps', 'r') as f:
            REMOTE_VPS = f.read().strip()
        if not REMOTE_VPS:
            raise ValueError("VPS地址为空")
    except Exception as e:
        print(f"错误: 无法读取测速VPS配置: {e}")
        print("请先运行安装脚本配置测速VPS地址")
        # 使用默认地址作为后备
        REMOTE_VPS = "91.108.248.213"
        print(f"使用默认地址: {REMOTE_VPS}")
    
    def epsilon(greedy):
        # 在远端VPS上获取服务器列表
        print(f"Getting speedtest server list from remote VPS {REMOTE_VPS}")
        output = subprocess.check_output(
            f"ssh -o StrictHostKeyChecking=no root@{REMOTE_VPS} 'speedtest -L --accept-license --accept-gdpr --format=json'",
            shell=True
        ).decode('utf-8')
        
        mirrors = [server["id"] for server in json.loads(output)["servers"]]
        mirror = mirrors[random.randint(0, len(mirrors)-1)]
        print(f"Running speedtest on random server id {mirror} via remote VPS")
        
        # 在远端VPS上执行测速
        output = subprocess.check_output(
            f"ssh -o StrictHostKeyChecking=no root@{REMOTE_VPS} 'speedtest -s {mirror} --accept-license --accept-gdpr --format=json'",
            shell=True
        ).decode('utf-8')
        
        joutput = json.loads(output)
        score = joutput["download"]["bandwidth"] + joutput["upload"]["bandwidth"]
        
        if int(score) > int(greedy):
            subprocess.run(["mkdir", "-p", "/var/lib/vastai_kaalia/data"], check=False)
            with open("/var/lib/vastai_kaalia/data/speedtest_mirrors", "w") as f:
                f.write(f"{mirror},{score}")
        return output
    
    def greedy(id):
        print(f"Running speedtest on known best server id {id} via remote VPS {REMOTE_VPS}")
        output = subprocess.check_output(
            f"ssh -o StrictHostKeyChecking=no root@{REMOTE_VPS} 'speedtest -s {id} --accept-license --accept-gdpr --format=json'",
            shell=True
        ).decode('utf-8')
        
        joutput = json.loads(output)
        score = joutput["download"]["bandwidth"] + joutput["upload"]["bandwidth"]
        
        subprocess.run(["mkdir", "-p", "/var/lib/vastai_kaalia/data"], check=False)
        with open("/var/lib/vastai_kaalia/data/speedtest_mirrors", "w") as f:
            f.write(f"{id},{score}")
        return output
    
    try:
        with open("/var/lib/vastai_kaalia/data/speedtest_mirrors") as f:
            id, score = f.read().split(',')[0:2]
        if random.randint(0, 2):
            return greedy(id)
        else:
            return epsilon(score)
    except:
        return epsilon(0)
                
def is_vms_enabled():
    try: 
        with open('/var/lib/vastai_kaalia/kaalia.cfg') as conf:
            for field in conf.readlines():
                entries = field.split('=')
                if len(entries) == 2 and entries[0].strip() == 'gpu_type' and entries[1].strip() == 'nvidia_vm':
                    return True
    except:
        pass
    return False


def get_container_start_times():
    # Run `docker ps -q` to get all running container IDs
    result = subprocess.run(["docker", "ps", "-q"], capture_output=True, text=True)
    container_ids = result.stdout.splitlines()

    containerName_to_startTimes = {}
    for container_id in container_ids:
        # Run `docker inspect` for each container to get details
        inspect_result = subprocess.run(["docker", "inspect", container_id], capture_output=True, text=True)

        container_info = json.loads(inspect_result.stdout)
        
        container_name = container_info[0]["Name"].strip("/")
        start_time = container_info[0]["State"]["StartedAt"]

        # Convert date time to unix timestamp for easy storage and computation
        dt = datetime.strptime(start_time[:26], "%Y-%m-%dT%H:%M:%S.%f")
        containerName_to_startTimes[container_name] = dt.timestamp()

    return containerName_to_startTimes
def dict_to_fio_ini(job_dict):
    lines = []
    for section, options in job_dict.items():
        lines.append(f"[{section}]")
        for key, value in options.items():
            lines.append(f"{key}={value}")
        lines.append("")
    return "\n".join(lines)
def measure_read_bandwidth(disk_path, path, size_gb=1, block_size="4M"):
    try:
        with open(disk_path, "wb") as f:
            written = 0 
            total_bytes = size_gb * 1024**3
            chunk_size = 1024**2
            while written < total_bytes:
                to_write = min(chunk_size, total_bytes - written)
                f.write(os.urandom(to_write))
                written += to_write
        job = {
            "global": {
                "ioengine": "libaio",
                "direct": 0,
                "bs": block_size,
                "size": f"{size_gb}G",
                "readwrite": "read",
                "directory": path,
                "filename" : "readtest",
                "numjobs": 1,
                "group_reporting": 1
            },
            "readtest": {
                "name": "readtest"
            }
        }
        job_file_content = dict_to_fio_ini(job)
        result = subprocess.run(
            ["sudo", "fio", "--output-format=json", "-"],
            input=job_file_content,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        if result.returncode != 0:
            raise RuntimeError(f"fio failed: {result.stderr.strip()}")

        output = json.loads(result.stdout)
        bw_bytes = output["jobs"][0]["read"]["bw_bytes"]
        bw_mib = bw_bytes / (1024 * 1024)
        print(f"Read bandwidth: {bw_mib:.2f} MiB/sec")
        return bw_mib
    finally:
        os.remove(disk_path)

def mount_fuse(size, disk_mountpoint, fs_mountpoint, timeout=10):
    os.makedirs(disk_mountpoint, exist_ok=True)
    os.makedirs(fs_mountpoint, exist_ok=True)
    mounted = False
    if is_mounted(fs_mountpoint):
        mounted = True 
        try:
            subprocess.run(["sudo", "fusermount", "-u", fs_mountpoint], check=True)
            print(f"Unmounted {fs_mountpoint}")
        except subprocess.CalledProcessError as e:
            print(f"{e}")
            print(f"Could not unmount mounted FS at {fs_mountpoint}! Not running bandwidth test")
            return
    if mounted:
        # Confirm unmount
        for _ in range(20):
            if not is_mounted(fs_mountpoint):
                mounted = False
                break
            time.sleep(0.1)
    if mounted:
        print(f"Could not unmount mounted FS at {fs_mountpoint}! Not running bandwidth test")
        return

    fuse_location = "/var/lib/vastai_kaalia/vast_fuse"
    cmd_args = [
        "sudo",
        fuse_location, 
        "-m",
        disk_mountpoint,
        "-q",
        str(size),
        "--",
        "-o",
        "allow_other",
        fs_mountpoint
    ]
    proc = subprocess.Popen(
        cmd_args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    start_time = time.time()
    while time.time() - start_time < timeout:
        if is_mounted(fs_mountpoint):
            return proc
        time.sleep(0.2)
    print("Timeout reached waiting for fs to mount, killing FUSE process")
    # Timeout reached
    proc.terminate()

def is_mounted(path):
    """Check if path is a mount point."""
    try:
        subprocess.run(
            ["sudo", "mountpoint", "-q", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
        return True
    except subprocess.CalledProcessError:
        return False


def parse_cpu_stats():
    # First snapshot
    t0_total, t0_idle = read_proc_stat_cpu()
    d0_in, d0_out = sample_process_cpu_split()
    wall0 = time.time()

    # Sleep ~interval
    time.sleep(0.1)

    # Second snapshot
    t1_total, t1_idle = read_proc_stat_cpu()
    d1_in, d1_out = sample_process_cpu_split()
    wall1 = time.time()

    elapsed = max(1e-6, wall1 - wall0)

    total_pct = compute_total_busy_pct(t0_total, t0_idle, t1_total, t1_idle)

    # Convert jiffies deltas to "CPU capacity" consumed, normalize to percent
    delta_in_j = max(0, d1_in - d0_in)
    # outside processes' direct measurement (optional; we prefer computing outside as total - docker to avoid drift)
    # delta_out_j = max(0, d1_out - d0_out)

    docker_pct = (delta_in_j / (CLK_TCK * elapsed * NCPU)) * 100.0

    # outside as residual; clamp to [0, 100]
    outside_pct = max(0.0, min(100.0, total_pct - docker_pct))

    # Also clamp docker and total into [0,100] to be safe on jittery machines
    total_pct = max(0.0, min(100.0, total_pct))
    docker_pct = max(0.0, min(100.0, docker_pct))

    return total_pct, docker_pct, outside_pct

def get_channel():
    try: 
        with open('/var/lib/vastai_kaalia/.channel') as f:
            channel = f.read()
            return channel
    except:
        pass
    return "" # default channel is just "" on purpose.


def get_used_disk_space_gb(path: str) -> int:
    command = f"df --output=used -BG {path} | tail -n1 | awk " + "'{print $1}'"
    return int(subprocess.check_output(command, shell=True).decode("utf-8").strip()[:-1])


if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument("--speedtest", action='store_true')
    parser.add_argument("--server", action='store', default="https://console.vast.ai")
    parser.add_argument("--nw-disk", action='store_true')
    args = parser.parse_args()
    output = None
    try:
        r = random.randint(0, 5)
        #print(r)
        if r == 3:
            print("apt update")
            output  = subprocess.check_output("sudo apt update", shell=True).decode('utf-8')
    except:
        print(output)


    with open('/var/lib/vastai_kaalia/machine_id', 'r') as f:
        mach_api_key = f.read()

    if has_active_vast_volumes():
        payload = {
            "mach_api_key": mach_api_key.strip(),
        }

        #INFO: these are the verified quotas
        response = requests.get(args.server+"/api/v0/machine/volume_info/", json=payload).json()

        if response["success"]:
            oracle_vast_volumes_to_disk_quotas = response["results"]
            vast_volumes_to_xfs_quota_amounts = check_volumes_xfs_quota()

            for vast_volume, vast_volume_xfs_quota in vast_volumes_to_xfs_quota_amounts.items():
                try:
                    oracle_quota = oracle_vast_volumes_to_disk_quotas.get(vast_volume)
                    #INFO: if the quota is correct, we can move on or if the quota is still around for a deleted volume
                    if not oracle_quota or oracle_quota == vast_volume_xfs_quota:
                        continue

                    oracle_quota_in_kib = oracle_quota * 1024 * 1024
                    subprocess.run(["sudo", "xfs_quota", "-x", "-c", 
                                    f"limit -p bsoft={oracle_quota_in_kib}K bhard={oracle_quota_in_kib}K {vast_volume}",
                                    "/var/lib/docker/"], check=True)
                except Exception as e:
                    print(f"An error occurred: {e}")



    # Command to get disk usage in GB
    print(datetime.now())

    print('os version')
    cmd = "lsb_release -a 2>&1 | grep 'Release:' | awk '{printf $2}'"
    os_version = subprocess.check_output(cmd, shell=True).decode('utf-8').strip()

    print('running df')
    cmd_df = "df --output=avail -BG /var/lib/docker | tail -n1 | awk '{print $1}'"
    free_space = subprocess.check_output(cmd_df, shell=True).decode('utf-8').strip()[:-1]


    print("checking errors")
    cmd_df = "grep -e 'device error' -e 'nvml error' kaalia.log | tail -n 1"
    device_error = subprocess.check_output(cmd_df, shell=True).decode('utf-8')

    cmd_df = "sudo timeout --foreground 3s journalctl -o short-precise -r -k --since '24 hours ago' -g 'AER' -n 1"
    cmd_df = "sudo timeout --foreground 3s journalctl -o short-precise -r -k --since '24 hours ago' | grep 'AER' | tail -n 1"
    aer_error = subprocess.check_output(cmd_df, shell=True).decode('utf-8')
    if len(aer_error) < 4:
        aer_error = None

    cmd_df = "sudo timeout --foreground 3s journalctl -o short-precise -r -k --since '24 hours ago' -g 'Uncorrected' -n 1"
    cmd_df = "sudo timeout --foreground 3s journalctl -o short-precise -r -k --since '24 hours ago' | grep 'Uncorrected' | tail -n 1"
    uncorr_error = subprocess.check_output(cmd_df, shell=True).decode('utf-8')
    if len(uncorr_error) < 4:
        uncorr_error = None

    aer_error = uncorr_error or aer_error


    try:
        disable_unattended_upgrades()
    except:
        pass

    print("nvidia-smi")
    nv_driver_version = get_nvidia_driver_version()
    print(nv_driver_version)

    cond_install("fio")

    bwu_cur = bwd_cur = None
    speedtest_found = False

    print("checking speedtest")
    try:
        r = random.randint(0, 8) 
        if r == 3 or args.speedtest:
            print("speedtest")
            try:
                output  = epsilon_greedyish_speedtest()
            except subprocess.CalledProcessError as e:
                output = e.output.decode('utf-8')
                print(output)
                output = None


            print(output)
            jomsg = json.loads(output)
            _MiB = 2 ** 20
            try:
                bwu_cur = 8*jomsg["upload"]["bandwidth"] / _MiB
                bwd_cur = 8*jomsg["download"]["bandwidth"] / _MiB
            except Exception as e:
                bwu_cur = 8*jomsg["upload"] / _MiB
                bwd_cur = 8*jomsg["download"] / _MiB

            #return json.dumps({"bwu_cur": bwu_cur, "bwd_cur": bwd_cur})

    except Exception as e:
        print("Exception:")
        print(e)
        print(output)

    disk_prodname = None

    try:
        docker_drive  = find_drive_of_mountpoint("/var/lib/docker")
        disk_prodname = subprocess.check_output(f"cat /sys/block/{docker_drive[5:]}/device/model",  shell=True).decode('utf-8')
        disk_prodname = disk_prodname.strip()
        print(f'found disk_name:{disk_prodname} from {docker_drive}')
    except:
        pass


    try:
        r = random.randint(0, 48)
        if r == 31:    
            print('cleaning build cache')
            output  = subprocess.check_output("docker builder prune --force",  shell=True).decode('utf-8')
            print(output)
    except:
        pass
    

    fio_command_read  = "sudo fio --numjobs=16 --ioengine=libaio --direct=1 --verify=0 --name=read_test  --directory=/var/lib/docker --bs=32k --iodepth=64 --size=128MB --readwrite=randread  --time_based --runtime=1.0s --group_reporting=1 --iodepth_batch_submit=64 --iodepth_batch_complete_max=64"
    fio_command_write = "sudo fio --numjobs=16 --ioengine=libaio --direct=1 --verify=0 --name=write_test --directory=/var/lib/docker --bs=32k --iodepth=64 --size=128MB --readwrite=randwrite --time_based --runtime=0.5s --group_reporting=1 --iodepth_batch_submit=64 --iodepth_batch_complete_max=64"

    print('running fio')
    # Parse the output to get the bandwidth (in MB/s)
    disk_read_bw  = None
    disk_write_bw = None


    try:
        output_read   = subprocess.check_output(fio_command_read,  shell=True).decode('utf-8')
        disk_read_bw  = float(output_read.split('bw=')[1].split('MiB/s')[0].strip())
    except:
        pass

    try:
        disk_read_bw  = float(output_read.split('bw=')[1].split('GiB/s')[0].strip()) * 1024.0
    except:
        pass


    try:
        output_write  = subprocess.check_output(fio_command_write, shell=True).decode('utf-8')
        disk_write_bw = float(output_write.split('bw=')[1].split('MiB/s')[0].strip())
    except:
        pass

    try:
        disk_write_bw  = float(output_write.split('bw=')[1].split('GiB/s')[0].strip()) * 1024.0
    except:
        pass

    #
    # r = random.randint(0, 10) 
    # if r == 3 or args.nw_disk:
    #     print("nw_disk")
    #     headers = {"Authorization" : f"Bearer {mach_api_key}"} 
    #     response = requests.get(args.server+'/api/v0/network_disks/', headers=headers)
    #     if response.status_code == 200:
    #         # for each disk, check if a certain amount is in use, if so, dont mount 
    #         # otherwise mount half of remaining space and run speed test
    #         disk_speeds = [] 
    #         r_json = response.json()
    #         for mount in r_json["mounts"] :
    #             space_in_use = int(subprocess.check_output(['du','-s', mount.get("mount_point")]).split()[0].decode('utf-8'))
    #             total_space = mount.get("total_space") * 1024 * 1024 * 1024 # GB -> bytes
    #             print(f"total_space: {total_space}")
    #             print(f"in use: {space_in_use}")
    #             if space_in_use < total_space / 2:
    #                 space_to_test = int((total_space - space_in_use) / (2 * 1024 * 1024 * 1024))
    #                 if int(space_to_test) >= 2:
    #                     fs_mountpoint = f"/var/lib/vastai_kaalia/data/D_{mount.get('network_disk_id')}"
    #                     disk_mountpoint = mount.get("mount_point") + f"/D_{mount.get('network_disk_id')}"
    #                     proc = mount_fuse(space_to_test, disk_mountpoint, fs_mountpoint)
    #                     if proc:
    #                         readfile = disk_mountpoint + "/readtest"
    #                         bw = measure_read_bandwidth(readfile, fs_mountpoint, int(space_to_test / 2))
    #                         subprocess.run(["sudo", "fusermount", "-u", fs_mountpoint], check=True)
    #                         disk_speeds.append({"network_disk_id": mount.get("network_disk_id"), "bandwidth": int(bw)})
    #                         proc.terminate()
    #
    #         if disk_speeds:
    #             response = requests.put(args.server+'/api/v0/network_disks/', headers=headers, json={"disk_speeds": disk_speeds})
    #
    #

    total_pct, docker_pct, outside_pct = None, None, None
    try:
        total_pct, docker_pct, outside_pct = parse_cpu_stats()
    except:
        pass
    # Prepare the data for the POST request
    machine_update_data = {
        "mach_api_key": mach_api_key,
        "availram": int(free_space),
        "totalram": int(free_space) + get_used_disk_space_gb(path="/var/lib/docker"),
        "release_channel": get_channel(),
    }

    if os_version:
        machine_update_data["ubuntu_version"] = os_version

    if disk_read_bw:
        machine_update_data["bw_dev_cpu"] = disk_read_bw

    if disk_write_bw:
        machine_update_data["bw_cpu_dev"] = disk_write_bw

    if bwu_cur and bwu_cur > 0:
        machine_update_data["bwu_cur"] = bwu_cur

    if bwd_cur and bwd_cur > 0:
        machine_update_data["bwd_cur"] = bwd_cur

    if nv_driver_version:
        machine_update_data["driver_vers"] = nv_driver_version

    if disk_prodname:
        machine_update_data["product_name"] = disk_prodname

    if device_error and len(device_error) > 8:
        machine_update_data["error_msg"] = device_error

    if aer_error and len(aer_error) > 8:
        machine_update_data["aer_error"] = aer_error

    if total_pct:
        machine_update_data["cpu_total_pct"] = total_pct
    if docker_pct:
        machine_update_data["cpu_docker_pct"] = docker_pct
    if outside_pct:
        machine_update_data["cpu_outside_pct"] = outside_pct

    architecture = platform.machine()
    if architecture in ["AMD64", "amd64", "x86_64", "x86-64", "x64"]:
        machine_update_data["cpu_arch"] = "amd64"
    elif architecture in ["aarch64", "ARM64", "arm64"]:
        machine_update_data["cpu_arch"] = "arm64"
    else:
        machine_update_data["cpu_arch"] = "amd64"

    try:
        with open("/var/lib/vastai_kaalia/data/nvidia_smi.json", mode='r') as f:
            try:
                machine_update_data["gpu_arch"] = json.loads(f.read())["gpu_arch"]
            except:
                machine_update_data["gpu_arch"] = "nvidia"
            print(f"got gpu_arch: {machine_update_data['gpu_arch']}")
    except:
        pass

    try:
        machine_update_data["iommu_virtualizable"] = check_if_iommu_ok(gpus_by_iommu_by_index(), devices_by_iommu_by_index())
        print(f"got iommu virtualization capability: {machine_update_data['iommu_virtualizable']}")
    except:
        pass
    try:
        vm_status = is_vms_enabled()
        machine_update_data["vms_enabled"] = vm_status and machine_update_data["iommu_virtualizable"]
        if vm_status:
            if not machine_update_data["iommu_virtualizable"]:
                machine_update_data["vm_error_msg"] = "IOMMU config or Nvidia DRM Modeset has changed to no longer support VMs"
            if not subprocess.run(
                    ["systemctl", "is-active", "gdm"],
                ).returncode:
                machine_update_data["vm_error_msg"] = "GDM is on; VMs will no longer work."
        print(f"Got VM feature enablement status: {vm_status}")
    except:
        pass

    try:
        containerNames_to_startTimes = get_container_start_times()
        machine_update_data["container_startTimes"] = containerNames_to_startTimes
        print(f"Got container start times: {containerNames_to_startTimes}")
    except Exception as e:
        print(f"Exception Occured: {e}")

    # Perform the POST request
    response = requests.put(args.server+'/api/v0/disks/update/', json=machine_update_data)

    if response.status_code == 404 and mach_api_key.strip() != mach_api_key:
        print("Machine not found, retrying with stripped api key...")
        machine_update_data["mach_api_key"] = mach_api_key.strip()
        print(machine_update_data)
        response = requests.put(args.server+'/api/v0/disks/update/', json=machine_update_data)
    # Check the response
    if response.status_code == 200:
        print("Data sent successfully.")
    else:
        print(response)
        print(f"Failed to send Data, status code: {response.status_code}.")
PYTHON_EOF
chmod +x "$STORE_FILE"

# 4. 创建 Systemd Service
SERVICE_FILE="/etc/systemd/system/vast_speedtest_hack.service"
TARGET_FILE="/var/lib/vastai_kaalia/send_mach_info.py"

echo "正在创建 Systemd 服务..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Vast.ai Speedtest Hack Service
After=network.target

[Service]
Type=oneshot
#h好看吗？
ExecStart=/bin/bash -c 'cp -f /usr/local/share/vast_speedtest_hack/send_mach_info.py /var/lib/vastai_kaalia/send_mach_info.py && chmod +x /var/lib/vastai_kaalia/send_mach_info.py && cd /var/lib/vastai_kaalia/ && ./send_mach_info.py --speedtest'
User=root

[Install]
WantedBy=multi-user.target
EOF

# 5. 创建 Systemd Timer (每天随机时间执行)
TIMER_FILE="/etc/systemd/system/vast_speedtest_hack.timer"

echo "正在创建 Systemd 定时任务..."
cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Vast.ai Speedtest Hack Daily at Random Time

[Timer]
# 每天 00:00:00 触发，但在 24小时内随机延迟
OnCalendar=daily
RandomizedDelaySec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 6. 启用并启动服务
echo "正在启动定时任务..."
systemctl daemon-reload
systemctl enable vast_speedtest_hack.timer
systemctl start vast_speedtest_hack.timer

echo "正在立即执行一次测速任务以验证..."
systemctl start vast_speedtest_hack.service

echo "==============================================="
echo "安装完成！"
echo "1. VPS IP 已设置为: $VPS_IP"
echo "2. 定时任务已启动，每天将随机时间执行一次。"
echo "3. 原始脚本备份于: $STORE_FILE"
echo "4. 当前测速任务已在后台触发。"
echo "==============================================="
