#!/bin/bash

##################################################################################
logLevel=1                                 # 0=None, 1=Info, 2=Debug, 3=Verbose  #
logMax=0                                   # Max log lines, 0=unlimited          #
                                           # logMax defaults to 50 if logrotate  #
                                           # is not set and no max is defined    #
                                           # and is ignored otherwise            #
                                           #######################################
logFile=/var/log/dnsupdater.log            # Log file location                   #
                                           #######################################
                                           # If you intend to use logrotate, set #
                                           # /etc/logrotate.d/dnsupdater to:     #
                                           # /var/log/dnsupdater.log {           #
                                           #     weekly                          #
                                           #     missingok                       #
                                           #     rotate 12                       #
                                           #     compress                        #
                                           #     notifempty                      #
                                           # }                                   #
                                           #######################################
credentials=/root/.creds/cloudflare        # Credential file location            #
                                           #######################################
                                           # Contents must be:                   #
                                           # auth_email="<Cloudflare email>"     #
                                           # auth_key="<Cloudflare API key>"     #
                                           #######################################
twilio=/root/.creds/twilio                 # Twilio credential file location     #
                                           #######################################
                                           # Contents must be:                   #
                                           # auth_sid="<twilio sid>"             #
                                           # auth_token="<twilio token>"         #
                                           # from_number="<+12225551212>"        #
                                           #######################################
sms_recipient="+13606075617"               # Number to send the SMS alert to     #
##################################################################################

# Set sudo if not runing elevated
if [ "$(whoami)" != "root" ]; then
  sudo="sudo"
fi

# Logging function
logit() {
    # Usage:
    # logit 1 "Info logging" or
    # logit 2 "Debug logging"
    local level="$1"
    local logData="$2"
    [[ "$logLevel" -ge "$level" ]] && echo "$logData" | $sudo tee -a "$logFile"
}

# SMS sending function
send_sms() {
    local to_number="$1"
    local message="$2"
    if [[ -z "$to_number" || -z "$message" ]]; then
        echo "Usage: send_sms <to_number> <message> [media_url]"
        return 1
    fi
    # Send the message
    sms_response=$(curl -s -X POST "https://api.twilio.com/2010-04-01/Accounts/$auth_sid/Messages.json" \
        --data-urlencode "To=$to_number" \
        --data-urlencode "From=$from_number" \
        --data-urlencode "Body=$message" \
        -u "$auth_sid:$auth_token"
    )
    if echo "$response" | jq -e '.success' > /dev/null; then
        logit 2 "SMS sent to $to_number"
        logit 3 "SMS send response:"
        logit 3 "$(echo "$sms_response" | jq .)"
    else
        retries=$((retries - 1))
        logit 1 "Retrying update... ($retries retries left)"
        sleep 2
    fi
}

# Clean up temp/working files and exit script
quit() {
    local exitLevel="$1"
    [[ "$logLevel" -gt 0 ]] && echo "$logging logging available at $logFile"
    logit 1 "------------------------------"
    exit $exitLevel
}

# Name logging level
[[ "$logLevel" -eq 1 ]] && logging="Standard"
[[ "$logLevel" -eq 2 ]] && logging="Debug"
[[ "$logLevel" -eq 3 ]] && logging="Verbose"

# Initialize logging, set log file for current run
logit 1 "DNS check $(date '+%Y-%m-%d %H:%M:%S')"
logit 2 "Log level is set to $logging"

# Verify dependencies
for cmd in curl jq awk; do
    command -v $cmd >/dev/null || { logit 1 "$cmd is not installed. Exiting."; quit 1; }
done

# Check if a domain name was passed as an argument
if [ -z "$1" ]; then
    echo "Usage: $0 <FQDN>"
    logit 1 "No FQDN provided"
    quit 1
else
    fqdn="$1"
    logit 2 "Checking DNS record for $fqdn"
    # Extract the domain from the FQDN (e.g., "sub.example.com" -> "example.com")
    domain=$(echo "$fqdn" | awk -F. '{print $(NF-1)"."$NF}')
    logit 2 "\$fqdn = $fqdn"
    logit 2 "\$domain = $domain"
fi

# Retrieve Cloudshare credentials
logit 2 "Starting Cloudshare credential retrieval"
if $sudo test -r "$credentials"; then
    # Read credentials from the file
    auth_email=$($sudo awk -F= '/^auth_email/ {print $2}' "$credentials" | tr -d '"')
    auth_key=$($sudo awk -F= '/^auth_key/ {print $2}' "$credentials" | tr -d '"')
    # Check if credentials were loaded
    if [[ -z "$auth_key" || -z "$auth_email" ]]; then
        logit 1 "Failed to load credentials from $credentials"
        quit 1
    fi
    logit 2 "Cloudshare credentials retrieved from $credentials"
else
    logit 1 "$credentials not readable"
    quit 1
fi

# Retrieve Twilio credentials
logit 2 "Starting Twilio credential retrieval"
if $sudo test -r "$twilio"; then
    # Read credentials from the file
    auth_sid=$($sudo awk -F= '/^auth_sid/ {print $2}' "$twilio" | tr -d '"')
    auth_token=$($sudo awk -F= '/^auth_token/ {print $2}' "$twilio" | tr -d '"')
    from_number=$($sudo awk -F= '/^from_number/ {print $2}' "$twilio" | tr -d '"')
    # Check if credentials were loaded
    if [[ -z "$auth_sid" || -z "$auth_token" || -z "$from_number" ]]; then
        logit 1 "Failed to load credentials from $twilio"
        quit 1
    fi
    logit 2 "Twilio credentials retrieved from $twilio"
else
    logit 1 "\$twilio not readable"
    quit 1
fi

# Fetch and parse account information for the extracted domain
logit 2 "Starting domainID retrieval"
domainID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
    -H "X-Auth-Key: $auth_key" \
    -H "X-Auth-Email: $auth_email" \
    -H "Content-Type: application/json" | jq --arg domain "$domain" -r '.result[] | select(.name == $domain) | .id')
logit 2 "\$domainID = $domainID"

# Check if data was found
if [ -z "$domainID" ]; then
    logit 1 "Domain ID not found for $domain, exiting sript"
    quit 1
fi

# Get DNS records
logit 2 "Starting dnsRecords retrieval"
dnsRecords=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$domainID/dns_records" \
    -H "X-Auth-Email: $auth_email" \
    -H "X-Auth-Key: $auth_key" \
    -H "Content-Type: application/json")

# Extract relevant data for the given FQDN
if [ -z "$dnsRecords" ]; then
    logit 1 "No DNS records retrieved"
    quit 1
else
    logit 2 "Starting recordDetails retrieval"
    recordDetails=$(echo "$dnsRecords" | jq --arg fqdn "$(echo "$fqdn" | tr '[:upper:]' '[:lower:]')" -r '
        .result[]
        | select(has("type") and .type == "A" and (has("name") and (.name | ascii_downcase) == $fqdn))
        | {content: .content, id: .id, ttl: .ttl, zone_id: .zone_id}')
    logit 2 "All record names and types:"
    logit 2 "$(echo "$dnsRecords" | jq -r '.result[] | "\(.name) - \(.type)"')"
    logit 3 "\$recordDetails for $fqdn = $recordDetails"
    logit 3 "Full dnsRecords:"
    logit 3 "$(echo "$dnsRecords" | jq .)"

    # Parse individual fields from JSON
    currentIP=$(echo "$recordDetails" | jq -r '.content')
    recordID=$(echo "$recordDetails" | jq -r '.id')
    ttl=$(echo "$recordDetails" | jq -r '.ttl')
    zoneID=$(echo "$recordDetails" | jq -r '.zone_id')

    # Check if required fields were retrieved
    if [[ -z "$currentIP" || -z "$recordID" || -z "$ttl" || -z "$zoneID" ]]; then
        logit 1 "Failed to retrieve record details for $fqdn"
        quit 1
    fi
fi

# Check if the IP address was found
if [ -z "$currentIP" ]; then
    logit 1 "No A record found for $fqdn"
    quit 1
else
    logit 2 "Current IP address for $fqdn is $currentIP"
fi

# Get new IP from ifconfig.co
logit 2 "Checking ifconfig.co for new IP address"
newIP=$(curl -s ifconfig.co)

# If actual IP not obtainable, do nothing and exit the script
if [[ "$newIP" == "" ]]; then
    logit 1 "Unable to get IP address from ifconfig.co"
    quit 1
fi

# compare $currentIP with $newIP, and if different, execute update
[[ "$currentIP" == "" ]] && currentIP="No IP address on record for $fqdn"
logit 2 "Compare current IP $currentIP"
logit 2 "         to new IP $newIP"

if [[ -n "$currentIP" && -n "$newIP" && "$currentIP" = "$newIP" ]]; then
    # Same IP, no update needed
    logit 1 "IP address for $fqdn $currentIP did not change"
else
    # different IP, execute update
    logit 2 "Updating DNS for $fqdn from $currentIP to $newIP"

    # API call to update DNS record
    retries=3
    while [[ $retries -gt 0 ]]; do
        response=$(curl --silent --show-error --request PATCH \
            --url "https://api.cloudflare.com/client/v4/zones/$zoneID/dns_records/$recordID" \
            --header "Content-Type: application/json" \
            --header "X-Auth-Email: $auth_email" \
            --header "X-Auth-Key: $auth_key" \
            --data "$(jq -n --arg name "$fqdn" \
                --arg content "$newIP" \
                --arg comment "Updated via $(basename "$0")" \
                --argjson ttl "$ttl" \
                    '{  comment: $comment,
                        name: $name,
                        proxied: false,
                        settings: {},
                        tags: [],
                        ttl: $ttl,
                        content: $content,
                        type: "A"
                    }'
            )"
        )
        if echo "$response" | jq -e '.success' > /dev/null; then
            logit 3 "DNS Update response:"
            logit 3 "$(echo "$response" | jq .)"
            break
        else
            retries=$((retries - 1))
            logit 1 "Retrying update... ($retries retries left)"
            sleep 2
        fi
    done
    [[ $retries -eq 0 ]] && { logit 1 "Failed to update DNS record after multiple attempts."; quit 1; }

    # Validate API response
    if echo "$response" | jq -e '.success' > /dev/null; then
        logit 1 "Successfully updated DNS record for $fqdn to $newIP"
        logit 2 "Sending SMS notification to $sms_recipient"
        send_sms $sms_recipient "Successfully updated DNS record for $fqdn to $newIP"
    else
        logit 1 "Failed to update DNS record for $fqdn."
        quit 1
    fi
fi

# Check if logrotate is not enabled and logMax is still 0
if [[ ! -f "/etc/logrotate.d/dnsupdater" && "$logMax" -eq 0 ]]; then
    logit 2 "Logrotate not configured. Setting logMax to default (50 lines)."
    logMax=50
fi

# Reduce log size to last $logMax lines if needed
if [[ "$logMax" -ne 0 ]]; then
    tail -n "$logMax" "$logFile" > "${logFile}.tmp" && mv "${logFile}.tmp" "$logFile"
    logit 2 "Log truncated to the last $logMax lines."
fi

# End cleanup and end script
quit 0
