# Dynamic DNS updater for Cloudflare using the REST API

The won't update Cloudflare unless your IP address changes and it works with a free Cloudflare account

Current IP address is retrieved from [ifconfig.co](https://ifconfig.co)

The *.sh files should be placed in ```/etc/dnsupdater/```

The credential files should be placed in ```/root/.creds/``` and set with read-only permissions for the root user

```bash
sudo chmod 0400 /root/.creds/twilio
```
```bash
sudo chmod 0400 /root/.creds/cloudflare
```

Schedule the script to run every 15 minutes with a root cron job

```bash
(sudo crontab -l; echo "*/15    *        *       *       *      /etc/dnsupdater/dnsupdater.sh") | sudo crontab -
```

