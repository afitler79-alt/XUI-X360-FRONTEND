use ./xui11.sh.fixed.sh --yes-install --skip-apt-wait to install on linux

USE:
sudo sh -c 'printf "%s ALL=(root) NOPASSWD: %s, %s\n" "$USER" "$HOME/.xui/bin/xui_startup_and_dashboard.sh" "$HOME/.xui/bin/xui_start.sh" > /etc/sudoers.d/xui-dashboard-$USER'
sudo chmod 0440 /etc/sudoers.d/xui-dashboard-$USER
sudo visudo -cf /etc/sudoers.d/xui-dashboard-$USER
FOR SOLVING SUDO PROBLEMS
