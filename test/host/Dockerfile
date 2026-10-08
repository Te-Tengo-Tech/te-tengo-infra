# Stand-in for the EC2 instance: Ubuntu 24.04 with systemd as PID 1, like the real AMI. Ansible reaches
# it through the community.docker.docker connection (no SSH) as the `ubuntu` user with sudo, and
# installs Docker Engine inside it (Docker-in-Docker; the container runs privileged).
FROM ubuntu:24.04

ENV container=docker \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates python3 python3-apt sudo iproute2 iptables kmod \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
      systemd-modules-load.service sys-kernel-config.mount sys-kernel-debug.mount getty.target \
      systemd-logind.service console-getty.service \
 && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu \
 && chmod 0440 /etc/sudoers.d/90-ubuntu

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
