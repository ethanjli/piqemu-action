# PiQEMU GitHub Action

GitHub action to use QEMU to run commands in a VM on a Raspberry Pi SD card image

Unless you need to start and interact with the Docker daemon on your Raspberry Pi SD card image,
you probably don't need to use this action; instead, you can perform those operations inside a
`systemd-nspawn` container (or even just a chroot) attached to your image, which will be much
simpler, easier, and faster, e.g. using the
[`ethanjli/pinspawn-action`](https://github.com/ethanjli/pinspawn-action)
GitHub action (which you can use as a very similar substitute substitute for this action) or the
[`Nature40/pimod`](https://github.com/Nature40/pimod) GitHub action.

## Basic Usage Examples

Note: the system in the VM will shut down after the specified commands finish running.

### Run shell commands as root

```yaml
- name: Analyze systemd boot process
  uses: ethanjli/piqemu-action@v0.1.0
  with:
    image: rpi-os-image.img
    machine: rpi-3b+
    run: |
      while ! systemd-analyze 2>/dev/null; do
        echo "Waiting for boot to finish..."
        sleep 5
      done
      systemd-analyze critical-chain | cat
      systemd-analyze blame | cat
      systemd-analyze plot > /run/external/bootup-timeline.svg
      echo "Done!"

- name: Extract the bootup timeline from the VM
  uses: ethanjli/pinspawn-action@v0.1.1
  with:
    image: rpi-os-image.img
    args: --bind "$(pwd)":/run/external
    run: |
      mv /var/lib/bootup-timeline.svg /run/external/bootup-timeline.svg

- name: Upload the bootup timeline to Job Artifacts
  uses: actions/upload-artifact@v4
  with:
    name: bootup-timeline
    path: bootup-timeline.svg
    if-no-files-found: error
    overwrite: true
```

### Run shell commands as a non-root user

```yaml
- name: Run as user pi in booted container
  uses: ./
  with:
    image: rpi-os-image.img
    machine: rpi-3b+
    user: pi
    run: |
      sudo apt-get update
      sudo apt-get install -y cowsay
      /usr/games/cowsay "I am $USER!"
```

### Interact with Docker in a booted RPi 3B+ VM

```yaml
- name: Install Docker and pull a container
  uses: ./
  with:
    image: rpi-os-image.img
    machine: rpi-3b+
    run: |
      # Install Docker:
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y ca-certificates curl
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update
      apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

      # Pre-download a container:
      sudo docker pull cgr.dev/chainguard/crane:latest

- name: Run pre-downloaded container
  uses: ./
  with:
    image: rpi-os-image.img
    machine: rpi-3b+
    run: |
      docker images cgr.dev/chainguard/crane
      docker run --pull=never --rm cgr.dev/chainguard/crane:latest \
        manifest cgr.dev/chainguard/crane:latest --platform=linux/amd64
```

### Run setup scripts from an external source in a booted RPi 3B+ VM

TODO

## Usage Options

Inputs:

| Input         | Allowed values                     | Required?            | Description                                             |
|---------------|------------------------------------|----------------------|---------------------------------------------------------|
| `image`       | file path                          | yes                  | Path of the image to use for the VM.                    |
| `machine`     | `rpi-3b+`                          | yes                  | The type of machine to emulate.                         |
| `args`        | `qemu-system-aarch64` options/args | no (default ``)      | Options/args to pass to `qemu-system-aarch64`.          |
| `shell`       | ``, `bash`, `sh`, `python`, etc.   | no (default ``)      | The shell to use for running commands.                  |
| `run`         | shell commands                     | no (default ``)      | Commands to run in the shell.                           |
| `user`        | name of user in image              | no (default `root`)  | The user to run commands as.                            |
| `run-service` | file path                          | no (default ``)      | systemd service to run `shell` with the `run` commands. |

- `image` must be the path of an unmounted raw disk image (such as a Raspberry Pi OS SD card image),
  where partition 2 should be mounted as the root filesystem (i.e. `/`) and partition 1 should be
  mounted to `/boot`.

` `machine` controls the hardware which the VM will emulate. Currently only the Raspberry Pi 3B+
  (`rpi-3b+`) is supported; I can add support for other options depending on what people are
  interested in - so if you want some other machine type, please file a feature request!

  - Raspberry Pi 4 emulation is possible in QEMU but is not yet supported by this action,
    because I haven't been able to get internet access from the Raspberry Pi 4 machine type; this is
    because QEMU support for the RPi 4B is
    [still very new](https://9to5linux.com/qemu-9-0-released-with-raspberry-pi-4-support-loongarch-kvm-acceleration)
    and only partially implemented.

  - Generic ARM64 emulation is possible with QEMU's
    [`virt`](https://www.qemu.org/docs/master/system/riscv/virt.html) machine type and is probably
    faster than RPi-specific emulation, but then we have to compile a Linux kernel (which I have
    attempted successfully, and which is described in
    [this guide](https://gist.github.com/cGandom/23764ad5517c8ec1d7cd904b923ad863)). The problem is
    that then the Linux
    [kernel modules](https://linux-kernel-labs.github.io/refs/heads/master/labs/kernel_modules.html)
    on the Raspberry Pi image won't work with a custom kernel - and such kernel modules are required
    by Docker. Then we'll need to distribute and supply the kernel modules in some other way, and I
    am not (yet) experienced enough with the Linux kernel to understand how to do that. This matters
    to me because Docker depends on various kernel modules (e.g. for iptables/nftables) to start -
    and I'm only using QEMU to interact with the Docker daemon, so I have no use for use the `virt`
    machine type myself.

- `args` can be a list of command-line options/arguments for
  [`qemu-system-aarch64`](https://manpages.ubuntu.com/manpages/noble/man1/qemu-system.1.html).
  These arguments will be added to arguments automatically generated by this action.

- If `run` is not left empty, `shell` will be used to execute commands specified in the `run` input.
  You can use built-in `shell` keywords, or you can define a custom set of shell options. The shell
  command that is run internally executes a temporary file that contains the commands to run, like
  [in GitHub Actions](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#jobsjob_idstepsshell).
  Please refer to the GitHub Actions semantics of the `shell` keyword of job steps for details
  about the behavior of this action's `shell` input.

  If you just want to run a single script, you can leave `run` empty and provide that script as the
  `shell` input. However, you will need to set the appropriate permissions on the script file.

- The provided `run` commands will be triggered by a temporary system service defined with the
  following template (unless you specify a different service file template using the `run-service`
  input):

  ```
  [Unit]
  Description=Run commands in booted OS
  After=getty.target

  [Service]
  Type=exec
  ExecStart=bash -c "\
    su - {user} -c '{command}; echo $? | tee {result}'; \
    echo Shutting down...; \
    shutdown now \
  " &
  StandardOutput=tty

  [Install]
  WantedBy=getty.target
  ```

  This service file template has string interpolation applied to the following strings:

  - `{user}` will be replaced with the value of the action's `user` input.
  - `{command}` will be replaced with a command to run your specified `run` commands using your
    specified `shell`
  - `{result}` will be replaced with the path of a temporary file whose contents will be checked
    after the VM finishes running to determine whether the command finished successfully
    (in which case the file should be the string `0`); this file is interpreted as holding a
    return code.
