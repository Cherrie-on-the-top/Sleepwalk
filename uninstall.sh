#!/bin/zsh
# Sleepwalk / 梦游 — remove the app and everything it changed.
# Asks for your password once (to restore sleep and remove the sudoers rule).
set -e

pkill -x Sleepwalk || true

# 1. Restore normal sleep
sudo /usr/bin/pmset -a disablesleep 0

# 2. Remove this user's passwordless rule, if set up
sudo /bin/rm -f "/etc/sudoers.d/sleepwalk-$(id -u)"

# 3. Move the app to the Trash (recoverable)
failed=0
for app in ~/Applications/Sleepwalk.app /Applications/Sleepwalk.app; do
  if [ -d "$app" ]; then
    if mv "$app" ~/.Trash/"Sleepwalk $(date +%Y%m%d-%H%M%S)-$$-${app:h:t}.app"; then
      echo "Moved to Trash: $app"
    else
      echo "Could not move $app. Drag it to the Trash yourself."
      failed=1
    fi
  fi
done

echo "Sleep is back to normal."
echo "If you added Sleepwalk to Login Items, remove it in System Settings → General → Login Items."
exit $failed
