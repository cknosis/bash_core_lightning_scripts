#!/bin/bash

# Check if lightning-cli is available
if ! command -v lightning-cli &> /dev/null; then
    echo "Error: lightning-cli not found. Ensure Core Lightning is installed and accessible."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Install it with 'sudo apt install jq'."
    exit 1
fi

# Fetch Bitcoin price from Coinbase API
BTC_PRICE_USD=$(curl -s 'https://api.coinbase.com/v2/prices/BTC-USD/spot' | jq -r '.data.amount')
echo "Price USD: $BTC_PRICE_USD"

# Check if price was fetched successfully
if [[ -z "$BTC_PRICE_USD" || ! "$BTC_PRICE_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Warning: Failed to fetch Bitcoin price from Coinbase API. Using fallback price: $102547.48"
    BTC_PRICE_USD=102547.48
fi

# Calculate price per satoshi in USD
SAT_PRICE_USD=$(echo "scale=8; $BTC_PRICE_USD / 100000000" | bc)

# Get current Unix timestamp (seconds)
CURRENT_TIME=$(date +%s)
echo "Current time: $CURRENT_TIME"

# Calculate timestamps for last day, week, and month
DAY_SECONDS=$((24 * 3600))    # 24 hours in seconds
WEEK_SECONDS=$((7 * 24 * 3600))  # 7 days in seconds
MONTH_SECONDS=$((30 * 24 * 3600)) # Approx 30 days in seconds
YEAR_SECONDS=$((365 * 24 * 3600)) # 365 days in seconds

LAST_DAY=$((CURRENT_TIME - DAY_SECONDS))
LAST_WEEK=$((CURRENT_TIME - WEEK_SECONDS))
LAST_MONTH=$((CURRENT_TIME - MONTH_SECONDS))
LAST_YEAR=$((CURRENT_TIME - YEAR_SECONDS))

echo "Last Day: $LAST_DAY"
echo

# Get listforwards output
FORWARDS=$(lightning-cli listforwards)
# echo "FORWARDS: $FORWARDS"

# Count settled forwards for each time period
COUNT_DAY=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"settled\" and .received_time >= $LAST_DAY)] | length")
COUNT_WEEK=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"settled\" and .received_time >= $LAST_WEEK)] | length")
COUNT_MONTH=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"settled\" and .received_time >= $LAST_MONTH)] | length")
COUNT_ALL=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"settled\")] | length")

# Calculate fees for each time period (in_msat - out_msat for settled forwards)
FEE_DAY=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"settled\" and .received_time >= $LAST_DAY) | (.in_msat - .out_msat)] | add // 0")
FEE_WEEK=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"settled\" and .received_time >= $LAST_WEEK) | (.in_msat - .out_msat)] | add // 0")
FEE_YEAR=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"settled\" and .received_time >= $LAST_YEAR) | (.in_msat - .out_msat)] | add // 0")

# Convert msat to sat for readability
FEE_DAY_SAT=$(echo "scale=0; $FEE_DAY / 1000" | bc)
FEE_WEEK_SAT=$(echo "scale=0; $FEE_WEEK / 1000" | bc)
FEE_YEAR_SAT=$(echo "scale=0; $FEE_YEAR / 1000" | bc)

FEE_DAY_USD=$(echo "scale=2; $FEE_DAY_SAT * $SAT_PRICE_USD" | bc)
FEE_WEEK_USD=$(echo "scale=2; $FEE_WEEK_SAT * $SAT_PRICE_USD" | bc)
FEE_YEAR_USD=$(echo "scale=2; $FEE_YEAR_SAT * $SAT_PRICE_USD" | bc)

# Count failed forwards for each time period
FCOUNT_DAY=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"failed\" and .received_time >= $LAST_DAY)] | length")
FCOUNT_WEEK=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"failed\" and .received_time >= $LAST_WEEK)] | length")
FCOUNT_MONTH=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"failed\" and .received_time >= $LAST_MONTH)] | length")
FCOUNT_ALL=$(echo "$FORWARDS" | jq "[.forwards[] | select(.status == \"failed\")] | length")

# Get the timestamp of the last settled forward
LAST_SETTLED=$(echo "$FORWARDS" | jq '[.forwards[] | select(.status == "settled") | .received_time] | max')
if [ "$LAST_SETTLED" != "null" ] && [ -n "$LAST_SETTLED" ]; then
    LAST_SETTLED_HUMAN=$(date -d "@$LAST_SETTLED" 2>/dev/null || date -r "$LAST_SETTLED" 2>/dev/null)
else
    LAST_SETTLED_HUMAN="No settled forwards found"
fi

# Get the timestamp of the last failed forward
LAST_FAILED=$(echo "$FORWARDS" | jq '[.forwards[] | select(.status == "failed") | .received_time] | max')
if [ "$LAST_FAILED" != "null" ] && [ -n "$LAST_FAILED" ]; then
    LAST_FAILED_HUMAN=$(date -d "@$LAST_FAILED" 2>/dev/null || date -r "$LAST_FAILED" 2>/dev/null)
else
    LAST_FAILED_HUMAN="No failed forwards found"
fi

# Print results with human-readable dates
echo
echo "Number of payments routed (settled):"
echo "  Last 24 hours (since $(date -d @$LAST_DAY)): $COUNT_DAY"
echo "  Last week (since $(date -d @$LAST_WEEK)): $COUNT_WEEK"
echo "  Last month (since $(date -d @$LAST_MONTH)): $COUNT_MONTH"
echo "  All: $COUNT_ALL"

# Print results with human-readable dates
echo
echo "Number of payments routed (failed):"
echo "  Last 24 hours (since $(date -d @$LAST_DAY)): $FCOUNT_DAY"
echo "  Last week (since $(date -d @$LAST_WEEK)): $FCOUNT_WEEK"
echo "  Last month (since $(date -d @$LAST_MONTH)): $FCOUNT_MONTH"
echo "  All: $FCOUNT_ALL"

echo
echo "Last payment timestamps:"
echo "  Last settled payment: $LAST_SETTLED_HUMAN"
echo "  Last failed payment: $LAST_FAILED_HUMAN"
echo
# Print results with human-readable dates
echo "Forwarding Fees Collected (as of $(date)):"
echo "  Last 24 hours (since $(date -d @$LAST_DAY)): $FEE_DAY_SAT sat ($FEE_DAY msat) = \$$FEE_DAY_USD USD"
echo "  Last week (since $(date -d @$LAST_WEEK)): $FEE_WEEK_SAT sat ($FEE_WEEK msat) = \$$FEE_WEEK_USD USD"
echo "  Last year (since $(date -d @$LAST_YEAR)): $FEE_YEAR_SAT sat ($FEE_YEAR msat) = \$$FEE_YEAR_USD USD"
echo "  (Based on 1 BTC = \$$BTC_PRICE_USD, source: Coinbase API, fetched $(date))"
