# Stand-in for the production VM (Azure, Ubuntu 24.04; or the inactive OCI A1): systemd as PID 1,
# OpenSSH, and an iptables policy file shaped like the one of Oracle's Ubuntu images (not loaded: with
# cloud_provider oci the base role's firewall tasks edit it; with azure they must leave it untouched). Ansible reaches it over plain SSH as the `ubuntu` user with
# sudo, as in production, and installs Docker Engine inside it (Docker-in-Docker; privileged).
FROM ubuntu:26.04

ENV container=docker \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates python3 python3-apt sudo iproute2 iptables kmod openssh-server \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
      systemd-modules-load.service sys-kernel-config.mount sys-kernel-debug.mount getty.target \
      systemd-logind.service console-getty.service \
 && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu \
 && chmod 0440 /etc/sudoers.d/90-ubuntu \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/60-te-tengo-test.conf \
 && systemctl enable ssh.service

COPY oci-rules.v4 /etc/iptables/rules.v4

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
