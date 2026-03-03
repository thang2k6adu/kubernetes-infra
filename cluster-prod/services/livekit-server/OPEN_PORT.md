```bash
nano ~/k3s-inventory/open_livekit_ports.yml
```

Nội dung:

```yaml
- name: Open LiveKit ports on nodes
  hosts: master:workers
  become: yes

  tasks:
    - name: Allow TCP 7880 (LiveKit signaling)
      ufw:
        rule: allow
        port: "7880"
        proto: tcp

    - name: Allow TCP 7881 (RTC TCP fallback)
      ufw:
        rule: allow
        port: "7881"
        proto: tcp

    - name: Allow UDP range 50000-60000 (WebRTC media)
      ufw:
        rule: allow
        port: "50000:60000"
        proto: udp

    - name: Enable UFW
      ufw:
        state: enabled
        policy: allow
```

Lưu file:

* `Ctrl + O` → Enter
* `Ctrl + X`

---

## Lệnh chạy

```bash
ansible-playbook -i ~/k3s-inventory/hosts.ini ~/k3s-inventory/open_livekit_ports.yml
```

---

## Kiểm tra sau khi chạy (trên node)

```bash
sudo ufw status
```

Phải thấy:

```
7880/tcp
7881/tcp
50000:60000/udp
```

checkl <nnodeip>:7880 -> ra ok là được