#!/bin/bash

# Path to lightning-cli
LIGHTNING_CLI_PATH="/usr/local/bin/lightning-cli"

# Check if lightning-cli exists at the specified path
if [ ! -x "$LIGHTNING_CLI_PATH" ]; then
    echo "Error: lightning-cli not found at $LIGHTNING_CLI_PATH. Ensure Core Lightning is installed and the path is correct."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Install it with 'sudo apt install jq'."
    exit 1
fi

# Check if bc is installed
if ! command -v bc &> /dev/null; then
    echo "Error: bc is not installed. Install it with 'sudo apt install bc'."
    exit 1
fi

# Determine the network (e.g., bitcoin, testnet)
NETWORK=""
GETINFO=$($LIGHTNING_CLI_PATH getinfo 2>/dev/null)
if [ $? -eq 0 ]; then
    NETWORK=$(echo "$GETINFO" | jq -r '.network // "bitcoin"')
else
    # Fallback: Check directory structure
    if [ -d "/home/cknosis/.lightning/bitcoin" ]; then
        NETWORK="bitcoin"
    elif [ -d "/home/cknosis/.lightning/testnet" ]; then
        NETWORK="testnet"
    else
        echo "Error: Could not determine network. Ensure /home/cknosis/.lightning/<network> exists."
        exit 1
    fi
fi

# Update lightning-cli command to specify the network
LIGHTNING_CLI="$LIGHTNING_CLI_PATH --network=$NETWORK"

# Default log file path
DEFAULT_LOG_FILE="/logs/.lightning/lightningd.log"

# Read log file location from config
CONFIG_FILE="/home/cknosis/.lightning/config"
if [ -f "$CONFIG_FILE" ]; then
    LOG_FILE=$(grep '^log-file=' "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    if [ -z "$LOG_FILE" ]; then
        echo "Warning: log-file not specified in $CONFIG_FILE. Using default: $DEFAULT_LOG_FILE"
        LOG_FILE="$DEFAULT_LOG_FILE"
    fi
else
    echo "Warning: Config file not found at $CONFIG_FILE. Using default: $DEFAULT_LOG_FILE"
    LOG_FILE="$DEFAULT_LOG_FILE"
fi

# Check if log file exists
if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file not found at $LOG_FILE. Ensure Core Lightning is logging."
    exit 1
fi

# Determine log file start time
FIRST_LOG_LINE=$(head -n 1 "$LOG_FILE")
if [[ "$FIRST_LOG_LINE" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
    LOG_START_TIME=$(date -d "${BASH_REMATCH[1]}" +%s 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Warning: Could not parse log start time. Assuming 30 days of data."
        LOG_START_TIME=$((CURRENT_TIME - 30 * 24 * 60 * 60))
    fi
else
    echo "Warning: Log file format unexpected. Assuming 30 days of data."
    LOG_START_TIME=$((CURRENT_TIME - 30 * 24 * 60 * 60))
fi

# Calculate log duration
CURRENT_TIME=$(date +%s)
LOG_DURATION_SECONDS=$((CURRENT_TIME - LOG_START_TIME))
LOG_DURATION_DAYS=$((LOG_DURATION_SECONDS / (24 * 60 * 60)))

# Time period: Use log duration or 30 days, whichever is smaller
PERIOD_SECONDS=$((30 * 24 * 60 * 60))
if [ "$LOG_DURATION_SECONDS" -lt "$PERIOD_SECONDS" ]; then
    PERIOD_SECONDS=$LOG_DURATION_SECONDS
fi
START_TIME=$((CURRENT_TIME - PERIOD_SECONDS))

# Validate START_TIME
if [[ ! "$START_TIME" =~ ^[0-9]+$ ]]; then
    echo "Error: START_TIME is not a valid integer. Setting to 30 days ago."
    START_TIME=$((CURRENT_TIME - 30 * 24 * 60 * 60))
fi

# Calculate node uptime using syslog
SYSLOG_FILES="/var/log/syslog /var/log/syslog.*"
NODE_DOWNTIME_SECONDS=0
PREV_STOP_TIME=$START_TIME

# Parse syslog for lightningd start/stop events
for SYSLOG_FILE in $SYSLOG_FILES; do
    if [ ! -f "$SYSLOG_FILE" ]; then
        continue
    fi

    # Extract start and stop events
    EVENTS=$(grep -E "systemd\[.*\]: (Started|Stopped) lightningd" "$SYSLOG_FILE" | awk '{print $1, $2, $3, $5, $6}')

    while IFS= read -r EVENT; do
        EVENT_TIME_STR=$(echo "$EVENT" | awk '{print $1, $2, $3}')
        EVENT_TYPE=$(echo "$EVENT" | awk '{print $5, $6}')

        # Convert event time to epoch (e.g., "May 23 08:15:00")
        EVENT_TIME=$(date -d "$EVENT_TIME_STR" +%s 2>/dev/null)
        if [ $? -ne 0 ] || [[ ! "$EVENT_TIME" =~ ^[0-9]+$ ]]; then
            echo "Warning: Failed to parse syslog timestamp '$EVENT_TIME_STR'. Skipping event."
            continue
        fi

        # Skip events before the period start
        if [ "$EVENT_TIME" -lt "$START_TIME" ]; then
            continue
        fi

        # Skip events after current time
        if [ "$EVENT_TIME" -gt "$CURRENT_TIME" ]; then
            continue
        fi

        if [ "$EVENT_TYPE" = "Stopped lightningd" ]; then
            PREV_STOP_TIME=$EVENT_TIME
        elif [ "$EVENT_TYPE" = "Started lightningd" ] && [ "$PREV_STOP_TIME" -ge "$START_TIME" ]; then
            DOWNTIME=$((EVENT_TIME - PREV_STOP_TIME))
            NODE_DOWNTIME_SECONDS=$((NODE_DOWNTIME_SECONDS + DOWNTIME))
        fi
    done <<< "$EVENTS"
done

# If the node was stopped and not restarted, assume downtime until now
LAST_STOP=$(grep -E "systemd\[.*\]: Stopped lightningd" $SYSLOG_FILES | tail -n 1 | awk '{print $1, $2, $3}')
if [ -n "$LAST_STOP" ]; then
    LAST_STOP_TIME=$(date -d "$LAST_STOP" +%s 2>/dev/null)
    if [ $? -eq 0 ] && [[ "$LAST_STOP_TIME" =~ ^[0-9]+$ ]] && [ "$LAST_STOP_TIME" -gt "$START_TIME" ] && [ "$LAST_STOP_TIME" -gt "$PREV_STOP_TIME" ]; then
        DOWNTIME=$((CURRENT_TIME - LAST_STOP_TIME))
        NODE_DOWNTIME_SECONDS=$((NODE_DOWNTIME_SECONDS + DOWNTIME))
    fi
fi

# Calculate node uptime percentage
NODE_UPTIME_SECONDS=$((PERIOD_SECONDS - NODE_DOWNTIME_SECONDS))
if [ "$NODE_UPTIME_SECONDS" -lt 0 ]; then
    NODE_UPTIME_SECONDS=0
fi
NODE_UPTIME_PERCENT=$(echo "scale=2; $NODE_UPTIME_SECONDS / $PERIOD_SECONDS * 100" | bc)

# Function to get peer alias (if available)
get_peer_alias() {
    local peer_id=$1
    local alias=$($LIGHTNING_CLI listnodes "$peer_id" | jq -r '.nodes[0].alias // "Unknown"')
    echo "$alias"
}

# Get list of peers and channels
PEERS=$($LIGHTNING_CLI listpeers | jq -r '.peers[] | .id' 2>/dev/null)
CHANNELS=$($LIGHTNING_CLI listpeerchannels | jq -r '.channels[]' 2>/dev/null)

# Check if peers and channels data is available
if [ -z "$PEERS" ] || [ -z "$CHANNELS" ]; then
    echo "Error: Could not retrieve peers or channels. Check if Core Lightning is running and the network is correct."
    exit 1
fi

echo "Node and Peer Channel Uptime Report (Last 30 Days, as of $(date)):"
echo "Log File: $LOG_FILE"
echo "Log Duration: $LOG_DURATION_DAYS days of information"
echo "--------------------------------------------------"
echo "Node Uptime (cknosis8lightning.online):"
echo "Estimated Uptime: $NODE_UPTIME_PERCENT% (Downtime: $NODE_DOWNTIME_SECONDS seconds)"
echo "--------------------------------------------------"

# Process each peer
for PEER_ID in $PEERS; do
    # Get peer alias
    ALIAS=$(get_peer_alias "$PEER_ID")

    # Get channels for this peer
    PEER_CHANNELS=$(echo "$CHANNELS" | jq -r "select(.peer_id == \"$PEER_ID\") | .channel_id")

    # Skip if no channels exist for this peer
    if [ -z "$PEER_CHANNELS" ]; then
        echo "Peer: $PEER_ID ($ALIAS) - No active channels."
        continue
    fi

    # Process each channel for the peer
    for CHANNEL_ID in $PEER_CHANNELS; do
        # Get channel state
        STATE=$(echo "$CHANNELS" | jq -r "select(.channel_id == \"$CHANNEL_ID\") | .state")

        # Skip if channel is not in CHANNELD_NORMAL (not fully active)
        if [ "$STATE" != "CHANNELD_NORMAL" ]; then
            echo "Peer: $PEER_ID ($ALIAS) - Channel: $CHANNEL_ID - State: $STATE (Not active, skipping uptime calculation)."
            continue
        fi

        # Parse logs for disconnection events
        DISCONNECT_EVENTS=$(grep "$PEER_ID" "$LOG_FILE" | grep "Peer transient failure" | awk '{print $1}' | sed 's/\..*//')

        # Calculate total downtime
        DOWNTIME_SECONDS=0
        PREV_EVENT_TIME=$START_TIME

        while IFS= read -r EVENT_TIME_STR; do
            # Convert log timestamp (format: YYYY-MM-DDTHH:MM:SS) to epoch
            EVENT_TIME=$(date -d "$EVENT_TIME_STR" +%s 2>/dev/null)
            if [ $? -ne 0 ]; then
                continue
            fi

            # Skip events before the period start
            if [ "$EVENT_TIME" -lt "$START_TIME" ]; then
                continue
            fi

            # Skip events after current time
            if [ "$EVENT_TIME" -gt "$CURRENT_TIME" ]; then
                continue
            fi

            # Estimate downtime: Assume each disconnection lasts until the next reconnection or current time
            RECONNECT_TIME=$(grep "$PEER_ID" "$LOG_FILE" | grep -A 1 "$EVENT_TIME_STR" | grep "Peer with" | awk '{print $1}' | sed 's/\..*//' | head -n 1)
            if [ -n "$RECONNECT_TIME" ]; then
                RECONNECT_EPOCH=$(date -d "$RECONNECT_TIME" +%s 2>/dev/null)
                if [ $? -eq 0 ] && [ "$RECONNECT_EPOCH" -gt "$EVENT_TIME" ]; then
                    DOWNTIME=$((RECONNECT_EPOCH - EVENT_TIME))
                else
                    DOWNTIME=$((CURRENT_TIME - EVENT_TIME))
                fi
            else
                DOWNTIME=$((CURRENT_TIME - EVENT_TIME))
            fi

            DOWNTIME_SECONDS=$((DOWNTIME_SECONDS + DOWNTIME))
        done <<< "$DISCONNECT_EVENTS"

        # Calculate uptime percentage with error handling
        if [ -z "$PERIOD_SECONDS" ] || [ -z "$DOWNTIME_SECONDS" ]; then
            echo "Error: Unable to calculate uptime for Peer: $PEER_ID ($ALIAS), Channel: $CHANNEL_ID. Missing period or downtime data."
            continue
        fi
        UPTIME_SECONDS=$((PERIOD_SECONDS - DOWNTIME_SECONDS))
        # Ensure UPTIME_SECONDS is a valid integer
        if [[ ! "$UPTIME_SECONDS" =~ ^[0-9]+$ ]]; then
            echo "Warning: Uptime calculation failed for Peer: $PEER_ID ($ALIAS), Channel: $CHANNEL_ID. Setting uptime to 0%."
            UPTIME_SECONDS=0
        fi
        if [ "$UPTIME_SECONDS" -lt 0 ]; then
            UPTIME_SECONDS=0
        fi
        UPTIME_PERCENT=$(echo "scale=2; $UPTIME_SECONDS / $PERIOD_SECONDS * 100" | bc)

        # Display results
        echo "Peer: $PEER_ID ($ALIAS)"
        echo "Channel: $CHANNEL_ID"
        echo "State: $STATE"
        echo "Estimated Uptime: $UPTIME_PERCENT% (Downtime: $DOWNTIME_SECONDS seconds)"
        echo "--------------------------------------------------"
    done
done

# Additional node uptime check (system uptime)
NODE_UPTIME=$(uptime -s)
NODE_UPTIME_EPOCH=$(date -d "$NODE_UPTIME" +%s)
if [ "$NODE_UPTIME_EPOCH" -gt "$START_TIME" ]; then
    echo "Warning: Your system has been online since $NODE_UPTIME, which is less than the log duration."
    echo "Uptime calculations may be skewed due to system restarts."
fi
