#!/bin/bash
#
# record_toggle_elgato.sh - Toggle desktop + Elgato recording with shared mic audio
#
# Description:
#   Starts/stops one FFmpeg session that writes two recordings:
#   - Desktop screen video with microphone and desktop audio
#   - Elgato Cam Link 4K video with microphone audio
#
# Output:
#   - Raw desktop: ~/Videos/Recordings/YYYY-MM-DD/recording_HH-MM-SS_desktop.mkv
#   - Raw Elgato:  ~/Videos/Recordings/YYYY-MM-DD/recording_HH-MM-SS_elgato.mkv
#   - Final MOVs:  matching .mov files with PCM audio for Resolve

# --- CONFIGURATION ---
SAVE_BASE="$HOME/Videos/Recordings"
PID_FILE="/tmp/recording_elgato_combo_ffmpeg.pid"
PATH_FILE="/tmp/recording_elgato_combo_paths.txt"

# Video Devices
ELGATO_VIDEO="/dev/v4l/by-id/usb-Elgato_Cam_Link_4K_00054D144C000-video-index0"
ELGATO_FRAMERATE=25

# Audio Devices (PulseAudio/PipeWire Pulse compatibility)
DESKTOP_AUDIO="alsa_output.pci-0000_0d_00.6.analog-stereo.monitor"
MIC_AUDIO="alsa_input.usb-ZOOM_Corporation_ZOOM_P4_Audio_000000000000-00.analog-stereo"

# Voice Enhancement Settings (for male voice)
# Set to "true" to enable: highpass filter, EQ boost, and compression
# Set to "false" for raw mic audio (mono output)
ENABLE_VOICE_ENHANCEMENT=false

recording_is_running=false
if [ -f "$PID_FILE" ]; then
    REC_PID=$(cat "$PID_FILE")
    if kill -0 "$REC_PID" 2>/dev/null; then
        recording_is_running=true
    else
        rm -f "$PID_FILE" "$PATH_FILE"
    fi
fi

# --- TOGGLE LOGIC ---

if [ "$recording_is_running" = "true" ]; then
    # STOP RECORDING MODE
    DESKTOP_MKV=$(sed -n '1p' "$PATH_FILE")
    ELGATO_MKV=$(sed -n '2p' "$PATH_FILE")

    notify-send "Recording" "Stopping and converting desktop + Elgato recordings..."

    kill -INT "$REC_PID"
    while kill -0 "$REC_PID" 2>/dev/null; do sleep 0.5; done

    DESKTOP_MOV="${DESKTOP_MKV%.mkv}.mov"
    ELGATO_MOV="${ELGATO_MKV%.mkv}.mov"

    ffmpeg -i "$DESKTOP_MKV" -c:v copy -c:a pcm_s16le -map 0 "$DESKTOP_MOV" -y
    ffmpeg -i "$ELGATO_MKV" -c:v copy -c:a pcm_s16le -map 0 "$ELGATO_MOV" -y

    rm "$PID_FILE" "$PATH_FILE"
    notify-send "Recording Saved" "Ready for Resolve: $(basename "$DESKTOP_MOV"), $(basename "$ELGATO_MOV")"

else
    # START RECORDING MODE
    DATE=$(date +%Y-%m-%d)
    TIME=$(date +%H-%M-%S)
    mkdir -p "$SAVE_BASE/$DATE"

    DESKTOP_MKV="$SAVE_BASE/$DATE/recording_${TIME}_desktop.mkv"
    ELGATO_MKV="$SAVE_BASE/$DATE/recording_${TIME}_elgato.mkv"
    printf '%s\n%s\n' "$DESKTOP_MKV" "$ELGATO_MKV" > "$PATH_FILE"

    if [ ! -e "$ELGATO_VIDEO" ]; then
        notify-send "Recording Error" "Elgato video device not found: $ELGATO_VIDEO"
        rm "$PATH_FILE"
        exit 1
    fi

    # Detect primary screen position dynamically (supports multi-monitor setups)
    PRIMARY_INFO=$(xrandr --query | grep -E "connected.*primary" | grep -oE "[0-9]+x[0-9]+\+[0-9]+\+[0-9]+")
    if [ -z "$PRIMARY_INFO" ]; then
        notify-send "Recording Error" "Could not detect primary screen"
        rm "$PATH_FILE"
        exit 1
    fi
    PRIMARY_OFFSET=$(echo "$PRIMARY_INFO" | sed 's/.*+\([0-9]\+\)+\([0-9]\+\).*/\1,\2/')

    ERROR_LOG="/tmp/recording_elgato_combo_ffmpeg_error.log"

    # Inputs:
    #   0: desktop video, 1: Elgato video, 2: desktop audio, 3: microphone
    if [ "$ENABLE_VOICE_ENHANCEMENT" = "true" ]; then
        MIC_FILTER="[3:a]pan=mono|c0=c0[mic_mono],[mic_mono]highpass=f=85,equalizer=f=3000:t=q:w=2:g=3,compand=attacks=0.3:decays=0.8:points=-80/-80|-60/-60|-40/-20|-20/-5|0/0[mic_processed]"
        MIC_OUTPUT="mic_processed"
    else
        MIC_FILTER="[3:a]pan=mono|c0=c0[mic_mono]"
        MIC_OUTPUT="mic_mono"
    fi

    notify-send "Recording" "Started: Desktop + Elgato with shared mic"

    nohup ffmpeg -thread_queue_size 1024 -f x11grab -video_size 3840x2160 -framerate 30 -i :0.0+$PRIMARY_OFFSET \
    -thread_queue_size 1024 -f v4l2 -input_format nv12 -video_size 3840x2160 -framerate "$ELGATO_FRAMERATE" -i "$ELGATO_VIDEO" \
    -thread_queue_size 1024 -f pulse -i "$DESKTOP_AUDIO" \
    -thread_queue_size 1024 -f pulse -i "$MIC_AUDIO" \
    -filter_complex "[0:v]setpts=PTS-STARTPTS[desktop_v];[1:v]setpts=PTS-STARTPTS[elgato_v];$MIC_FILTER;[$MIC_OUTPUT]aresample=48000:async=1:first_pts=0,asplit=2[mic_desktop][mic_elgato];[2:a]aresample=48000:async=1:first_pts=0[desktop_48k]" \
    -map "[desktop_v]" -map "[mic_desktop]" -map "[desktop_48k]" \
    -c:v libx264 -preset ultrafast -crf 18 -r 30 \
    -c:a flac -compression_level 12 \
    "$DESKTOP_MKV" \
    -map "[elgato_v]" -map "[mic_elgato]" \
    -c:v libx264 -preset ultrafast -crf 18 -r "$ELGATO_FRAMERATE" \
    -c:a flac -compression_level 12 \
    "$ELGATO_MKV" > "$ERROR_LOG" 2>&1 &

    echo $! > "$PID_FILE"

    sleep 1
    if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        rm -f "$PID_FILE" "$PATH_FILE"
        notify-send "Recording Error" "FFmpeg exited during startup. See $ERROR_LOG"
        exit 1
    fi
fi
