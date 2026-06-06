# Oracle Cloud Free ARM Instance

A bash script to automatically claim a free-tier ARM Ampere A1 instance on Oracle Cloud. The script uses the official OCI CLI to retry instance creation until a slot becomes available.

Oracle's free tier offers a generous ARM instance with **4 OCPUs and 24 GB of RAM**. The problem is that resources are extremely limited — trying to create an instance through the web console usually results in an **"Out of host capacity"** error. This script automates the retry process with smart error handling so you don't have to keep clicking.

**Inspired by** following PowerShell Windows solution: https://github.com/HotNoob/Oracle-Free-Arm-VPS-PS/tree/main

## Features

- **Adaptive random cooldown** — different wait times per error type (capacity, rate limit, network)
- **File logging** — all attempts logged to `oci_a1_retry.log` with timestamps
- **Status file** — quick status check via `oci_a1_status.txt`
- **Graceful shutdown** — `Ctrl+C` cleanly exits and updates status
- **Auto-stop on success** — script stops and logs public IP + SSH command
- **Fatal error detection** — auto-stops on config errors that won't resolve by retrying
- **Connection pre-check** — validates OCI CLI setup before starting the loop
- **Configurable** via `.env` file — OCPU, RAM, disk size, max retries, and more
- **POSIX-compatible** — works on any Linux distro (no `grep -P` dependency)

## Setup

1. Install the Oracle Cloud CLI for Linux/Unix: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm#InstallingCLI__linux_and_unix
2. Login to your Oracle Cloud account in the browser: https://cloud.oracle.com/
3. Go to Profile -> My Profile (User information OCID) and copy the **user OCID** somewhere
4. Go to Profile -> Tenancy (Tenancy information OCID) and copy the value into the `.env` file as `TENANCY_ID`
5. Go to Profile -> My profile -> API keys
   - Click on "Add API key" and download the private and public key
6. Configure OCI by running following command in your terminal: `oci setup config`
   - In the console prompt fill in the **user OCID (step 3**) and **tenancy OCID (step 4)**
   - Select your region number (e.g. type in `24` for `eu-frankfurt-1`)
   - Press `n` to use the existing key previously generated
   - Provide the path to the private key file previously downloaded in step 5
   - Config should be written now and we already added the API key in step 5
   - **Note**: In case you are asked for a profile name: Type in "DEFAULT"

7. Execute following command to get a list of possible images. Select one and copy it into the `.env` variable `IMAGE_ID`:
```bash
oci compute image list --all -c "$TENANCY_ID" --auth api_key | jq -r '.data[] | select(.["display-name"] | contains("aarch64")) | "\(.["display-name"]): \(.id)"'
```
8. To get a list of possible Subnets, which you can save in the `.env` variable `SUBNET_ID`:
```bash
oci network subnet list -c "$TENANCY_ID" --auth api_key | jq -r '.data[] | "\(.["display-name"]): \(.id)"'
```
9. Copy the availability domain into the `.env` variable `AVAILABILITY_DOMAIN`:
```bash
oci iam availability-domain list -c "$TENANCY_ID" --auth api_key | jq -r '.data[].name'
```
10. Change the variable `PATH_TO_PUBLIC_SSH_KEY` in the `.env` file to point to your public SSH key
    - Either download it from the Oracle Cloud instance creation website or [generate an SSH key yourself](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#generating-a-new-ssh-key)

## Configuration

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

### Required Variables

| Variable | Description |
|----------|-------------|
| `TENANCY_ID` | Tenancy OCID from Oracle Cloud |
| `IMAGE_ID` | Image OCID (ARM/aarch64) — see step 7 |
| `SUBNET_ID` | Subnet OCID — see step 8 |
| `AVAILABILITY_DOMAIN` | Availability domain — see step 9 |
| `PATH_TO_PUBLIC_SSH_KEY` | Path to your SSH public key file |

### Optional Variables (uncomment in `.env` to override)

| Variable | Default | Description |
|----------|---------|-------------|
| `OCPU` | `4` | CPU cores (max 4 for free tier) |
| `MEMORY` | `24` | RAM in GB (max 24 for free tier) |
| `BOOT_VOLUME` | `100` | Disk size in GB |
| `PROFILE` | `DEFAULT` | OCI CLI profile name |
| `MAX_RETRIES` | `1000` | Max attempts (set `0` for infinite) |

## Run Script

```bash
chmod +x oracle_cloud_instance_creator.sh
```

### Foreground (see output live)
```bash
./oracle_cloud_instance_creator.sh
```

### Background (recommended)
```bash
nohup ./oracle_cloud_instance_creator.sh &
```

### Monitor Progress
```bash
# Watch live log
tail -f oci_a1_retry.log

# Quick status check
cat oci_a1_status.txt
```

### Stop Script
```bash
kill $(pgrep -f oracle_cloud_instance_creator.sh)
```

## Error Handling

The script handles errors with adaptive random cooldowns:

| Error | Cooldown | Action |
|-------|----------|--------|
| `Out of host capacity` | 2–5 min | Keep retrying — normal when no slots available |
| `TooManyRequests` / 429 | 3–10 min | Rate limited — longer backoff |
| Network / timeout | 2–4 min | Network issue — retry |
| `InvalidParameter` | **Stop** | Config error — fix your `.env` |
| `NotAuthorizedOrNotFound` | **Stop** | Permission issue — check IAM/API key |
| `LimitExceeded` | **Stop** | Quota exhausted — request increase |
| Other errors | 1–3 min | Unknown — retry with log |

## After Getting an Instance

When the script succeeds, it will log:
- Instance ID
- Public IP address
- SSH command to connect

```bash
ssh -i ~/.ssh/your-private-key ubuntu@<PUBLIC_IP>
```

## Tips

- **Region matters**: Some regions have more availability than others. Try less popular regions (e.g. Mumbai, Frankfurt) instead of Singapore or Ashburn
- **Start small**: 1 OCPU / 6 GB is easier to get than 4 OCPU / 24 GB. You can resize later
- **Be patient**: It can take hours to days. Run the script in the background on a server
- **Check quota**: Make sure you haven't exhausted your free tier quota (4 OCPU total)