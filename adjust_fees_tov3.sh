#!/bin/bash

# Fetch channel and funds data once
CHANNELS=$(lightning-cli listpeerchannels | jq '.channels[]')
FUNDS=$(lightning-cli listfunds | jq '.channels[]')

# Get unique list of short_channel_ids upfront
CHANNEL_IDS=$(echo "$CHANNELS" | jq -r '.short_channel_id' | sort -u)
if [[ -z "$CHANNEL_IDS" ]]; then
    echo "Error: No short_channel_ids found. Check lightning-cli listchannels output."
    exit 1
fi

# Convert CHANNEL_IDS to an array for controlled iteration
readarray -t CHANNEL_ARRAY <<< "$CHANNEL_IDS"
echo "Processing ${#CHANNEL_ARRAY[@]} channels..."

# : <<'END_COMMENT'

# Loop over the array
for CHANNEL in "${CHANNEL_ARRAY[@]}"; do
    echo "Processing channel: $CHANNEL"

    # Extract capacity and local balance from listfunds
    CAPACITY=$(echo "$FUNDS" | jq -r "select(.short_channel_id==\"$CHANNEL\") | .amount_msat // empty")
    CAPACITY=${CAPACITY%msat}
    LOCAL_BALANCE=$(echo "$FUNDS" | jq -r "select(.short_channel_id==\"$CHANNEL\") | .our_amount_msat // empty")
    LOCAL_BALANCE=${LOCAL_BALANCE%msat}
    THEIR_FEE=$(echo "$CHANNELS" | jq -r "select(.short_channel_id==\"$CHANNEL\") | .updates.remote.fee_proportional_millionths // empty")
    THEIR_FEE=${THEIR_FEE%msat}

# Check if THEIR_FEE is a valid number (integer or floating-point)
    echo "THEIR_FEE before adjustments: $THEIR_FEE"
    if [[ ! $THEIR_FEE =~ ^[+-]?[0-9]*\.?[0-9]+$ ]]; then
        echo "Error: THEIR_FEE ('$THEIR_FEE') is not a valid number. Setting to 20."
        THEIR_FEE=20
    fi
    if [[ "$THEIR_FEE" > 16 ]]; then
# Subtract 1 from THEIR_FEE using bc for arithmetic
        THEIR_FEE=$(echo "$THEIR_FEE - 1" | bc)
    fi
    if [[ "$THEIR_FEE" < 16 ]]; then
# Set minimum fee
        THEIR_FEE=17
    fi


# Print the result
    echo "THEIR_FEE (initial adjustments): $THEIR_FEE"

    echo "LOCAL_BALANCE: $LOCAL_BALANCE"
    echo "Capacity: $CAPACITY"

#: <<'END_COMMENT'

    # Validate CAPACITY and LOCAL_BALANCE
    if [[ -n "$CAPACITY" && "$CAPACITY" != "0" && "$CAPACITY" =~ ^[0-9]+$ && -n "$LOCAL_BALANCE" && "$LOCAL_BALANCE" =~ ^[0-9]+$ ]]; then
        LOCAL_RATIO=$(echo "$LOCAL_BALANCE / $CAPACITY" | bc -l)

        # Validate LOCAL_RATIO
        if [[ "$LOCAL_RATIO" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            if (( $(echo "$LOCAL_RATIO > 0.98" | bc -l) )); then
                echo "Channel $CHANNEL: LOCAL_RATIO=$LOCAL_RATIO, setting fees to 500/7"
                timeout 10 lightning-cli setchannel "$CHANNEL" 500 7
            elif (( $(echo "$LOCAL_RATIO > 0.2 && $LOCAL_RATIO < 0.98" | bc -l) )); then
                if (( $(echo "$THEIR_FEE < 16" | bc -l) )); then
                     echo "Ratio >0.2 && < 0.98.  $THEIR_FEE less than 16, setting to 17."
                     THEIR_FEE=17
                # Check if THEIR_FEE is greater than 128
                elif (( $(echo "$THEIR_FEE > 128" | bc -l) )); then
                    echo "Ratio >0.2 && < 0.98. $THEIR_FEE is greater than 128, setting to 128."
                    THEIR_FEE=128
                fi
                echo "Channel $CHANNEL: LOCAL_RATIO=$LOCAL_RATIO, setting fees to 888/$THEIR_FEE"
                timeout 10 lightning-cli setchannel "$CHANNEL" 888 "$THEIR_FEE"
            elif (( $(echo "$LOCAL_RATIO > 0.05 && $LOCAL_RATIO < 0.2" | bc -l) )); then
                THEIR_FEE=$(echo "$THEIR_FEE + 500" | bc)
                echo "Channel $CHANNEL: LOCAL_RATIO=$LOCAL_RATIO, setting fees to 1000/$THEIR_FEE"
                timeout 10 lightning-cli setchannel "$CHANNEL" 1000 "$THEIR_FEE"
            elif (( $(echo "$LOCAL_RATIO < 0.05 && $LOCAL_RATIO > 0.0001" | bc -l) )); then
                THEIR_FEE=$(echo "$THEIR_FEE + 1000" | bc)
                echo "Channel $CHANNEL: LOCAL_RATIO=$LOCAL_RATIO, setting fees to 1200/$THEIR_FEE"
                timeout 10 lightning-cli setchannel "$CHANNEL" 1200 "$THEIR_FEE"
            elif (( $(echo "$LOCAL_RATIO < 0.0001" | bc -l) )); then
                THEIR_FEE=$(echo "$THEIR_FEE + 2500" | bc)
                echo "Channel $CHANNEL: LOCAL_RATIO=$LOCAL_RATIO, setting fees to 1900/$THEIR_FEE"
                timeout 10 lightning-cli setchannel "$CHANNEL" 1900 "$THEIR_FEE"
            fi
        else
            echo "Skipping channel $CHANNEL: Invalid LOCAL_RATIO '$LOCAL_RATIO', using default fees 888/51"
            timeout 10 lightning-cli setchannel "$CHANNEL" 888 51
        fi
    else
        echo "Skipping channel $CHANNEL: Invalid or missing balance/capacity (Balance: $LOCAL_BALANCE, Capacity: $CAPACITY), using default fees 888/50"
        timeout 10 lightning-cli setchannel "$CHANNEL" 888 50
    fi
#END_COMMENT
done

echo "Script completed."
