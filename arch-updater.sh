#!/bin/bash

REQUIRED_PKGS=("topgrade" "yad" "notify-send" "checkupdates")
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v "$pkg" &> /dev/null; then
        echo "Error: $pkg is not installed"
        exit 1
    fi
done

# ==========================================
# 0. MANUAL CONTINUE (CONTINUE ARGUMENT)
# ==========================================
# To lock and unlock systems that have not been updated for more than 3 months
BLOCK_FILE="$HOME/.cache/arch_updater_blocked"
if [ "$1" == "continue" ]; then
    rm -f "$BLOCK_FILE"
    echo "Arch Updater: Otomatik güncelleme kilidi kaldırıldı. (Auto-update lock removed.)"
    notify-send -a "Arch Updater" -u normal "Servis Kilidi Açıldı" "Otomatik güncelleme kilidi başarıyla kaldırıldı."
    exit 0
fi

# If the system hasn't been updated for 6 months or more and the lock is not released, stop the script
if [ -f "$BLOCK_FILE" ]; then
    exit 0
fi

# ==========================================
# 1. ENVIRONMENT VARIABLES AND DISPLAY CONTROL
# ==========================================
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DISPLAY=:0
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# --- DISPLAY (GUI) READINESS CHECK ---
# Prevents startup race conditions. Waits until the desktop environment loads.
WAIT_TIME=0
MAX_WAIT=120
while [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && [ ! -e "/tmp/.X11-unix/X${DISPLAY#*:}" ]; do
    sleep 5
    WAIT_TIME=$((WAIT_TIME + 5))
    if [ "$WAIT_TIME" -ge "$MAX_WAIT" ]; then exit 0; fi
done

# ==========================================
# 2. SINGLE INSTANCE LOCK (LOCK FILE)
# ==========================================
SCRIPT_PATH=$(realpath "$0")
LOCK_FILE="/tmp/arch_updater.lock"

exec 9> "$LOCK_FILE"
if ! flock -n 9; then exit 0; fi

# ==========================================
# SETTINGS AND VARIABLES
# ==========================================
LOG_FILE="$HOME/.cache/arch_updater_last_run"
LAST_CHECK_LOG="$HOME/.cache/arch_updater_last_check"
NEWS_ACK_LOG="$HOME/.cache/arch_updater_news_ack"
REBOOT_LOG="$HOME/.cache/arch_updater_reboot_time"
POST_UPDATE_FLAG="$HOME/.cache/arch_updater_post_action"
RETRY_COUNT_FILE="$HOME/.cache/arch_updater_news_retry"
CONFIG_DIR="$HOME/.config/arch-updater"
CONFIG_FILE="$CONFIG_DIR/settings.conf"

RSS_FEED_URL="https://archlinux.org/feeds/news/"
NEWS_PAGE_URL="https://archlinux.org/news/"
LANG_CHECK=$(echo "$LANG" | grep -iq "tr" && echo "TR" || echo "EN")

mkdir -p "$CONFIG_DIR"
[ ! -f "$LOG_FILE" ] && echo 0 > "$LOG_FILE"
[ ! -f "$LAST_CHECK_LOG" ] && echo "" > "$LAST_CHECK_LOG"
[ ! -f "$NEWS_ACK_LOG" ] && echo 0 > "$NEWS_ACK_LOG"
[ ! -f "$RETRY_COUNT_FILE" ] && echo 0 > "$RETRY_COUNT_FILE"
[ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE"

LAST_RUN_EPOCH=$(cat "$LOG_FILE")
NEWS_ACK_EPOCH=$(cat "$NEWS_ACK_LOG")
NEWS_RETRIES=$(cat "$RETRY_COUNT_FILE")
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

BOOT_TIME=$(awk '/btime/ {print $2}' /proc/stat)
PENDING_REBOOT=0

if [ -f "$REBOOT_LOG" ]; then
    LOGGED_REBOOT_TIME=$(cat "$REBOOT_LOG")
    if [ "$LOGGED_REBOOT_TIME" -gt "$BOOT_TIME" ]; then PENDING_REBOOT=1; fi
fi

# Helper function to securely save settings
update_config() {
    local key="$1"
    local val="$2"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${val}/" "$CONFIG_FILE"
    else
        echo "${key}=${val}" >> "$CONFIG_FILE"
    fi
}

# ==========================================
# 3. AT MOST 1 CHECK PER DAY CONDITION (SWITCH-BREAK LOGIC)
# ==========================================
TODAY=$(date +%Y-%m-%d)

# Eğer --retry veya --criticalupdate argümanı yoksa günde 1 kez kontrol et
if [[ "$1" != "--retry" && "$1" != "--criticalupdate" ]]; then
    LAST_CHECK_DATE=$(cat "$LAST_CHECK_LOG")
    if [ "$LAST_CHECK_DATE" = "$TODAY" ]; then
        exit 0
    fi
    echo "$TODAY" > "$LAST_CHECK_LOG"
fi

# ==========================================
# 4. INTERNET AND METERED CONNECTION CHECK
# ==========================================
if ! ping -c 1 -W 3 archlinux.org &> /dev/null; then exit 0; fi

METERED_STATUS=$(nmcli -t -f GENERAL.METERED dev show 2>/dev/null | grep -iE "^yes|^yes \(guessed\)" | head -n 1)
if [ -n "$METERED_STATUS" ]; then
    if [ "$IGNORE_METERED" = "1" ]; then
        : # Continue silently
    elif [ "$IGNORE_METERED" = "0" ]; then
        exit 0;
    else
        if [ "$LANG_CHECK" = "TR" ]; then
            M_TITLE="Sınırlı İnternet Kotası"
            M_MSG="Bağlanılan internet sınırlı kotaya sahip yine de güncellemeye devam edilsin mi?"
            M_CHK="Bu ayar kaydedilsin mi?"
            BTN_Y="Evet"; BTN_N="Hayır"
        else
            M_TITLE="Metered Connection"
            M_MSG="Should updates continue even if your internet connection has a limited data allowance?"
            M_CHK="Save this setting?"
            BTN_Y="Yes"; BTN_N="No"
        fi

        YAD_OUT=$(yad --title="$M_TITLE" --image=network-wireless --window-icon=dialog-warning \
            --text="$M_MSG\n" --form --field="$M_CHK:CHK" FALSE \
            --button="$BTN_Y:0" --button="$BTN_N:1" --center --ontop \
            --timeout=60 --timeout-indicator=bottom)

        YAD_EXIT=$?
        CHK_VAL=$(echo "$YAD_OUT" | awk -F'|' '{print $1}')

        if [ $YAD_EXIT -eq 0 ]; then
            [ "$CHK_VAL" = "TRUE" ] && update_config "IGNORE_METERED" "1"
        elif [ $YAD_EXIT -eq 1 ]; then
            [ "$CHK_VAL" = "TRUE" ] && update_config "IGNORE_METERED" "0"
            exit 0
        else exit 0; fi
    fi
fi

# ==========================================
# 5. PRE-UPDATE CHECK AND LOG PREPARATION
# ==========================================
PACMAN_UPDATES=$(checkupdates 2>/dev/null | wc -l)
AUR_UPDATES=0
if command -v yay &> /dev/null; then AUR_UPDATES=$(yay -Qua 2>/dev/null | wc -l)
elif command -v paru &> /dev/null; then AUR_UPDATES=$(paru -Qua 2>/dev/null | wc -l); fi

TOTAL_UPDATES=$((PACMAN_UPDATES + AUR_UPDATES))
SKIP_UPDATES=0

# Saving the number of pacman log lines before the update (for firmware checks)
PACMAN_LOG="/var/log/pacman.log"
PACMAN_LOG_BEFORE=$(wc -l < "$PACMAN_LOG" 2>/dev/null || echo 0)

if [ "$TOTAL_UPDATES" -eq 0 ]; then
    if [ "$PENDING_REBOOT" -eq 1 ]; then SKIP_UPDATES=1; else exit 0; fi
fi

# ==========================================
# 6. UPDATE DELAY CONTROL (Time-Based Warnings & Target Day)
# ==========================================
# Extract the timestamp from the latest pacman -Syu log
LAST_UPG_STR=$(grep -E "starting full system upgrade" /var/log/pacman.log 2>/dev/null | tail -n 1 | awk -F'[\\[\\]]' '{print $2}')

if [ -n "$LAST_UPG_STR" ]; then
    LAST_PACMAN_EPOCH=$(date -d "$LAST_UPG_STR" +%s 2>/dev/null)
else
    LAST_PACMAN_EPOCH=$(date +%s) # If not found, assume it is a new system
fi

CURRENT_EPOCH=$(date +%s)
DIFF_SEC=$((CURRENT_EPOCH - LAST_PACMAN_EPOCH))
DIFF_DAYS=$((DIFF_SEC / 86400))
ZAMAN_STR="${DIFF_DAYS} gün"
ZAMAN_STR_EN="${DIFF_DAYS} days"

# --- HAFTANIN BELİRLİ GÜNÜ ÇALIŞTIRMA KORUMASI ---
CURRENT_DOW=$(date +%u)
# Analyzer scriptinden gelen ayar yoksa varsayılan olarak Pazartesi(1) kabul et
TARGET_DOW=${TARGET_DOW:-1}

# Eğer retry VEYA criticalupdate bayrakları verilmemişse hedef günü kontrol et
if [[ "$1" != "--retry" && "$1" != "--criticalupdate" ]] && [ "$CURRENT_DOW" -ne "$TARGET_DOW" ]; then
    exit 0
fi

BLOCK_AUTO=0
WARN_MSG=""
WARN_MSG_EN=""

if [ "$DIFF_DAYS" -ge 1825 ]; then # 5 Years
    WARN_MSG="Sistem 5 yıldan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı çok yüksek, otomatik güncelleme engellendi. Güncelleme yapmanız önerilmez, önemli dosyaların yedeğini alıp temiz bir Arch Linux kurulumu yapmanız veya rolling release olmayan bir linux dağıtımı kullanmanız önerilir. Güncellemeyi manuel olarak (sudo pacman -Sy archlinux-keyring ve sudo pacman -Syu) başarıyla tamamlarsanız \"arch-updater continue\" yazarak servisin çalışmasına izin verebilirsiniz."
    WARN_MSG_EN="The system has not been updated for over 5 years ($ZAMAN_STR_EN). The probability of encountering issues is very high, automatic updates are blocked. Updating is not recommended; it is advised to back up important files and perform a clean Arch Linux installation. If you successfully complete the update manually, you can allow the service to run by typing \"arch-updater continue\"."
    BLOCK_AUTO=1
elif [ "$DIFF_DAYS" -ge 1095 ]; then # 3 Years
    WARN_MSG="Sistem 3 yıldan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı çok yüksek, otomatik güncelleme engellendi. Güncelleme yapmanız önerilmez, önemli dosyaların yedeğini alıp temiz bir Arch Linux kurulumu yapmanız önerilir. Güncellemeyi manuel olarak başarıyla tamamlarsanız \"arch-updater continue\" yazarak servisin çalışmasına izin verebilirsiniz."
    WARN_MSG_EN="The system has not been updated for over 3 years ($ZAMAN_STR_EN). The probability of encountering issues is very high, automatic updates are blocked. Updating is not recommended. If you successfully complete the update manually, you can allow the service to run by typing \"arch-updater continue\"."
    BLOCK_AUTO=1
elif [ "$DIFF_DAYS" -ge 912 ]; then # 2.5 Years
    WARN_MSG="Sistem 2.5 yıldan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı çok yüksek, otomatik güncelleme engellendi. Güncellemeyi manuel olarak başarıyla tamamlarsanız \"arch-updater continue\" yazarak servisin çalışmasına izin verebilirsiniz."
    WARN_MSG_EN="The system has not been updated for over 2.5 years ($ZAMAN_STR_EN). Automatic updates are blocked. If you successfully complete the update manually, you can allow the service to run by typing \"arch-updater continue\"."
    BLOCK_AUTO=1
elif [ "$DIFF_DAYS" -ge 730 ]; then # 2 Years
    WARN_MSG="Sistem 2 yıldan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı çok yüksek, otomatik güncelleme engellendi. Güncellemeyi manuel olarak başarıyla tamamlarsanız \"arch-updater continue\" yazarak servisin çalışmasına izin verebilirsiniz."
    WARN_MSG_EN="The system has not been updated for over 2 years ($ZAMAN_STR_EN). Automatic updates are blocked. If you successfully complete the update manually, you can allow the service to run by typing \"arch-updater continue\"."
    BLOCK_AUTO=1
elif [ "$DIFF_DAYS" -ge 547 ]; then # 1.5 Years
    WARN_MSG="Sistem 1.5 yıldan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı çok yüksek, otomatik güncelleme engellendi. Güncellemeyi manuel olarak başarıyla tamamlarsanız \"arch-updater continue\" yazarak servisin çalışmasına izin verebilirsiniz."
    WARN_MSG_EN="The system has not been updated for over 1.5 years ($ZAMAN_STR_EN). Automatic updates are blocked. If you successfully complete the update manually, you can allow the service to run by typing \"arch-updater continue\"."
    BLOCK_AUTO=1
elif [ "$DIFF_DAYS" -ge 365 ]; then # 1 Year
    WARN_MSG="Sistem 1 yıldan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı çok yüksek, otomatik güncelleme engellendi. Güncellemeyi manuel olarak başarıyla tamamlarsanız \"arch-updater continue\" yazarak servisin çalışmasına izin verebilirsiniz."
    WARN_MSG_EN="The system has not been updated for over 1 year ($ZAMAN_STR_EN). Automatic updates are blocked. If you successfully complete the update manually, you can allow the service to run by typing \"arch-updater continue\"."
    BLOCK_AUTO=1
elif [ "$DIFF_DAYS" -ge 270 ]; then # 9 Months
    WARN_MSG="Sistem 9 aydan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı çok yüksek, otomatik güncelleme engellendi. Güncellemeyi manuel olarak başarıyla tamamlarsanız \"arch-updater continue\" yazarak servisin çalışmasına izin verebilirsiniz."
    WARN_MSG_EN="The system has not been updated for over 9 months ($ZAMAN_STR_EN). Automatic updates are blocked. If you successfully complete the update manually, you can allow the service to run by typing \"arch-updater continue\"."
    BLOCK_AUTO=1
elif [ "$DIFF_DAYS" -ge 180 ]; then # 6 Months
    WARN_MSG="Sistem 6 aydan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı yüksek, otomatik güncelleme engellendi. Güncellemeyi manuel olarak başarıyla tamamlarsanız \"arch-updater continue\" yazarak servisin çalışmasına izin verebilirsiniz."
    WARN_MSG_EN="The system has not been updated for over 6 months ($ZAMAN_STR_EN). Automatic updates are blocked. If you successfully complete the update manually, you can allow the service to run by typing \"arch-updater continue\"."
    BLOCK_AUTO=1
elif [ "$DIFF_DAYS" -ge 90 ]; then # 3 Months
    WARN_MSG="Sistem 3 aydan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı yüksek, otomatik güncelleme engellendi. Güncellemeyi manuel olarak başarıyla tamamlarsanız \"arch-updater continue\" yazarak servisin çalışmasına izin verebilirsiniz."
    WARN_MSG_EN="The system has not been updated for over 3 months ($ZAMAN_STR_EN). Automatic updates are blocked. If you successfully complete the update manually, you can allow the service to run by typing \"arch-updater continue\"."
    BLOCK_AUTO=1
elif [ "$DIFF_DAYS" -ge 60 ]; then # 2 Months
    WARN_MSG="Sistem 2 aydan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı yüksek, güncelleme sonrası loga bakmanız önerilir."
    WARN_MSG_EN="The system has not been updated for over 2 months ($ZAMAN_STR_EN). The probability of encountering issues is high; checking the log after updating is recommended."
elif [ "$DIFF_DAYS" -ge 45 ]; then # 1.5 Months
    WARN_MSG="Sistem 1.5 aydan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı orta, güncelleme sonrası loga bakmanız önerilir."
    WARN_MSG_EN="The system has not been updated for over 1.5 months ($ZAMAN_STR_EN). The probability of encountering issues is medium; checking the log after updating is recommended."
elif [ "$DIFF_DAYS" -ge 30 ]; then # 1 Month
    WARN_MSG="Sistem 1 aydan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı orta, güncelleme sonrası loga bakmanız önerilir."
    WARN_MSG_EN="The system has not been updated for over 1 month ($ZAMAN_STR_EN). The probability of encountering issues is medium; checking the log after updating is recommended."
elif [ "$DIFF_DAYS" -ge 21 ]; then # 3 Weeks
    WARN_MSG="Sistem 3 haftadan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı az, güncelleme sonrası loga bakmanız önerilir."
    WARN_MSG_EN="The system has not been updated for over 3 weeks ($ZAMAN_STR_EN). The probability of encountering issues is low; checking the log after updating is recommended."
elif [ "$DIFF_DAYS" -ge 14 ]; then # 2 Weeks
    WARN_MSG="Sistem 2 haftadan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı az, güncelleme sonrası loga bakmanız önerilir."
    WARN_MSG_EN="The system has not been updated for over 2 weeks ($ZAMAN_STR_EN). The probability of encountering issues is low; checking the log after updating is recommended."
elif [ "$DIFF_DAYS" -ge 10 ]; then # 1.5 Weeks
    WARN_MSG="Sistem 1.5 haftadan fazla olan $ZAMAN_STR süredir güncelleme yapmadı. Sorun yaşanma olasılığı az, güncelleme sonrası loga bakmanız önerilir."
    WARN_MSG_EN="The system has not been updated for over 1.5 weeks ($ZAMAN_STR_EN). The probability of encountering issues is low; checking the log after updating is recommended."
fi

if [ -n "$WARN_MSG" ]; then
    if [ "$LANG_CHECK" = "TR" ]; then
        N_TITLE="⚠️ Güncelleme Uyarısı"
        N_MSG="$WARN_MSG"
    else
        N_TITLE="⚠️ Update Warning"
        N_MSG="$WARN_MSG_EN"
    fi

    if [ "$BLOCK_AUTO" -eq 1 ]; then
        notify-send -a "Arch Updater" -u critical -t 0 "$N_TITLE" "$N_MSG"
        touch "$BLOCK_FILE"
        exit 1 # Lock activated, update will not start
    else
        notify-send -a "Arch Updater" -u normal "$N_TITLE" "$N_MSG"
    fi
fi

# ==========================================
# 7. UPDATE BLOCKS (NEWS + TOPGRADE)
# ==========================================
JUST_UPDATED=0

if [ "$SKIP_UPDATES" -eq 0 ]; then

    # --- A. NEWS CHECK ---
    # More stable Regex parsing (-m 2) against corrupted XML structure
    RSS_PUBDATE=$(curl -s "$RSS_FEED_URL" | grep -m 2 -o '<pubDate>.*</pubDate>' | tail -n 1 | sed -e 's/<[^>]*>//g')
    if [ -n "$RSS_PUBDATE" ]; then LATEST_NEWS_EPOCH=$(date -d "$RSS_PUBDATE" +%s 2>/dev/null || echo 0); else LATEST_NEWS_EPOCH=0; fi

    if [ "$LATEST_NEWS_EPOCH" -gt "$NEWS_ACK_EPOCH" ]; then
        if [ "$NEWS_RETRIES" -ge 3 ]; then
            notify-send -a "Arch Updater" -u critical "Güncelleme İptal Edildi" "Haberler onaylanmadığı için sistem güvenliği gereği güncelleme iptal edildi."
            echo 0 > "$RETRY_COUNT_FILE"
            exit 0
        fi

        if [ "$LANG_CHECK" = "TR" ]; then
            MSG="Sistemin zarar görmemesi için güncelleme durduruldu!\nLütfen manuel müdahale gerektiren haberi okuyun.\n\nTarih: $RSS_PUBDATE"
            BTN="Haberi Aç"; TITLE="⚠️ Kritik Arch Haberi Bekliyor"
        else
            MSG="Updates are paused for your safety!\nPlease read the announcement requiring manual intervention.\n\nDate: $RSS_PUBDATE"
            BTN="Open News"; TITLE="⚠️ Critical Arch News Pending"
        fi

        ACTION=$(notify-send -a "Arch Updater" -u critical -t 0 -A "open=$BTN" "$TITLE" "$MSG")

        if [ "$ACTION" = "open" ]; then
            xdg-open "$NEWS_PAGE_URL"
            echo "$LATEST_NEWS_EPOCH" > "$NEWS_ACK_LOG"
            echo 1 > "$POST_UPDATE_FLAG"
            echo 0 > "$RETRY_COUNT_FILE"
        else
            echo $((NEWS_RETRIES + 1)) > "$RETRY_COUNT_FILE"
        fi

        systemd-run --user --on-active="2h" /bin/bash "$SCRIPT_PATH" --retry
        exit 0
    fi

    # --- B. SILENT UPDATE ---
    if [ "$1" == "--criticalupdate" ]; then
        if [ "$LANG_CHECK" = "TR" ]; then
            START_TITLE="🚨 Kritik Sistem Güncellemesi"
            START_MSG="Kritik güncelleme komutu alındı. Rutin bekleme süresi es geçilerek işlemler arka planda başlatıldı."
        else
            START_TITLE="🚨 Critical System Update"
            START_MSG="Critical update command received. Bypassing wait period, updates have started in the background."
        fi
    else
        if [ "$LANG_CHECK" = "TR" ]; then
            START_TITLE="Sistem Güncelleniyor"
            START_MSG="Haftalık güvenli güncelleme gününüz geldi! Güncelleme arka planda başladı, lütfen bildirim gelene kadar sistemi kapatmayın."
        else
            START_TITLE="System Updating"
            START_MSG="Your safe weekly update day is here! The update has started in the background; please do not restart until completion."
        fi
    fi
    notify-send -a "Arch Updater" -u normal "$START_TITLE" "$START_MSG"

    echo -e "\n=== UPDATE LOG: $(date) ===" > /tmp/arch_updater_topgrade.log

    # Run Topgrade command and record its status
    sudo topgrade -y >> /tmp/arch_updater_topgrade.log 2>&1
    TOPGRADE_EXIT=$?

    # --- BACKUP PROCESS (Last 7 Logs) ---
    LOG_BACKUP_DIR="$HOME/.cache/arch-updater/logs"
    mkdir -p "$LOG_BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp "/tmp/arch_updater_topgrade.log" "$LOG_BACKUP_DIR/arch_updater_${TIMESTAMP}.log" 2>/dev/null
    # Keep only the 7 most recent .log files, delete the rest
    ls -tp "$LOG_BACKUP_DIR"/arch_updater_*.log 2>/dev/null | grep -v '/$' | tail -n +8 | xargs -I {} rm -- "{}" 2>/dev/null

    if [ $TOPGRADE_EXIT -eq 0 ]; then
        date +%s > "$LOG_FILE"
        JUST_UPDATED=1

        # --- C. POST-UPDATE NEWS REMINDER ---
        if [ -f "$POST_UPDATE_FLAG" ] && [ "$(cat "$POST_UPDATE_FLAG")" = "1" ]; then
            if [ "$LANG_CHECK" = "TR" ]; then
                P_TITLE="Güncelleme Başarılı & Aksiyon Gerekli"
                P_MSG="Arka plan güncellemesi bitti. Lütfen News'e göre yapılması gereken manuel değişiklikleri tamamlayınız."
            else
                P_TITLE="Update Successful & Action Required"
                P_MSG="Background update complete. Please make any manual changes required by the News."
            fi
            notify-send -a "Arch Updater" -u critical -t 0 "$P_TITLE" "$P_MSG"
            rm -f "$POST_UPDATE_FLAG"
        fi
    else
        if [ "$LANG_CHECK" = "TR" ]; then
            E_TITLE="Güncelleme Başarısız!"
            E_MSG="Arka planda çalışırken bir hata oluştu. Lütfen /tmp/arch_updater_topgrade.log dosyasını inceleyin."
        else
            E_TITLE="Update Failed!"
            E_MSG="An error occurred in the background. Check /tmp/arch_updater_topgrade.log."
        fi
        notify-send -a "Arch Updater" -u critical -t 0 "$E_TITLE" "$E_MSG"
        exit 1
    fi
fi

# ==========================================
# 8. REBOOT CHECK (Advanced)
# ==========================================
REBOOT_NEEDED=0
if [ "$SKIP_UPDATES" -eq 0 ]; then
    CURRENT_KERNEL=$(uname -r)

    # 1. PACMAN LOG CHECK
    if [ "$JUST_UPDATED" -eq 1 ]; then
        PACMAN_LOG_AFTER=$(wc -l < "$PACMAN_LOG" 2>/dev/null || echo 0)
        NEW_LINES=$((PACMAN_LOG_AFTER - PACMAN_LOG_BEFORE))

        if [ "$NEW_LINES" -gt 0 ]; then
            # Core Arch components that require a reboot without a separate prompt
            CRITICAL_PKGS="linux|linux-lts|linux-zen|linux-hardened|linux-firmware.*|.*-ucode|systemd.*|glibc|dbus|nvidia.*|mesa|wayland|sddm|gdm|lightdm"

            # Scans only the log lines added (newly) since this script started running
            if tail -n "$NEW_LINES" "$PACMAN_LOG" | grep -iE "\[ALPM\] (upgraded|installed|removed) ($CRITICAL_PKGS) \(" > /dev/null 2>&1; then
                REBOOT_NEEDED=1
            fi
        fi
    fi

    # 2. SERVICE UPDATE CHECK (sudo added so it can read system-level daemons)
    if command -v needrestart &> /dev/null; then
        (sudo needrestart -b 2>/dev/null | grep -iq "NEEDRESTART-SVC-") && REBOOT_NEEDED=1
    fi

    # 3. KERNEL MODULE CHECK (Deletion of old kernel folder)
    if [ ! -d "/usr/lib/modules/$CURRENT_KERNEL" ]; then REBOOT_NEEDED=1; fi
fi

if [ "$REBOOT_NEEDED" -eq 1 ] || [ "$PENDING_REBOOT" -eq 1 ]; then
    date +%s > "$REBOOT_LOG"

    if [ "$LANG_CHECK" = "TR" ]; then
        TITLE="Sistem Yeniden Başlatma Gerekli"
        MSG="UYARI: Çekirdek (Kernel), donanım yazılımı (Firmware) veya kritik servisler güncellendi. İstikrar için sistemi şimdi yeniden başlatmak ister misiniz?"
        BTN="Yeniden Başlat"
    else
        TITLE="System Reboot Required"
        MSG="WARNING: Kernel, firmware, or core services have been updated. Would you like to reboot now for stability?"
        BTN="Reboot Now"
    fi

    ACTION=$(notify-send -u critical -t 15000 -A "reboot=$BTN" "$TITLE" "$MSG")

    if [ "$ACTION" = "reboot" ]; then
        # sudo is not required in the background; if there is an active loginctl session, systemctl works without issues.
        systemctl reboot
        exit 0
    else
        systemd-run --user --on-active="1h" /bin/bash "$SCRIPT_PATH" --retry
    fi
else
    # --- SUCCESSFUL UPDATE WITH NO REBOOT REQUIRED ---
    if [ "$JUST_UPDATED" -eq 1 ]; then
        if [ "$LANG_CHECK" = "TR" ]; then
            SUCCESS_TITLE="Güncelleme Başarılı"
            SUCCESS_MSG="Canlı (Live) aynalardan güncellemeler yapıldı. Yeniden başlatma zorunlu değil."
        else
            SUCCESS_TITLE="Update Successful"
            SUCCESS_MSG="Live updates have been applied. Restart is not required."
        fi
        notify-send -a "Arch Updater" -u normal "$SUCCESS_TITLE" "$SUCCESS_MSG"
    fi
fi

exit 0
