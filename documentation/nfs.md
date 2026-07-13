# Using nfs for kubernetes pods from a local nfs server

1. [Set up ubuntu specific nfs server](https://ubuntu.com/server/docs/how-to/networking/install-nfs/)
1. Ensure dns is set up properly, I use pi-hole for my dns server and added an entry for my ubuntu desktop
1. I had to open up the firewall rules 
```bash
# Check the current firewall rules
sudo ufw status verbose

# If not opened, allow port 2049
sudo ufw allow from 192.168.0.0/24 to any port nfs

# Check the current firewall rules
sudo ufw status verbose

To                         Action      From
--                         ------      ----
11434                      ALLOW IN    192.168.0.0/16
22                         ALLOW IN    192.168.0.0/16
2049                       ALLOW IN    192.168.0.0/24
```
### [To set up on another server](https://ubuntu.com/server/docs/how-to/networking/install-nfs/#nfs-client-configuration)

### [To set up a kubernetes csi driver](./helm-installs/nfs-csi-driver/DEPLOY.md)
