# WARNING
(!) Due to a bug in the current PCS version (soon to be fixed), token authentication in SMD has do be disabled. Which is what this script does.
Use for test systems only, not in a productive environment!

# Description
A script to set up [Power Control](https://github.com/OpenCHAMI/power-control) to be used in an existing OpenCHAMI installation.
(!) Note: This script expects an existing OpenBao integration as it is described [here](https://github.com/darkmatterdawn/OpenCHAMI-openbao-integration).
This procedure was developed for, and has been tested in, quadlet-based OpenCHAMI setups using recent openchami-release versions up until 0.1.9.
It has not been tested yet with release 0.2.0.

The setup mirrors what the OpenCHAMI quadlet setup in the openchami-release does, as in, the main container relies on an init-container.

Overall, this procedure makes the minimal amount of necessary changes to the existing OpenCHAMI setup and tries to keep things simple, similar and without too many dependencies, making maintenance and debugging easier.

# How to integrate PCS
```
sudo ./pcs-setup.sh 2>&1 | tee pcs-setup.log
```
Use `-f` to force the script execution without interactive user confirmation.

# Verification
```
# make sure the Redfish endpoint exists in SMD, username and password are set
# (see OpenBao example), and Redfish discovery is in status "DiscoverOK"
[user@demo ~]$ ochami smd rfe get -x x5000c0s0b0 -F yaml
RedfishEndpoints:
    - DiscoveryInfo:
        LastDiscoveryAttempt: "2026-08-21T07:49:21.346253Z"
        LastDiscoveryStatus: DiscoverOK
        RedfishVersion: 1.21.0
      Domain: openchami.cluster
      Enabled: true
      FQDN: x5000c0s0b0.openchami.cluster
      Hostname: x5000c0s0b0
      ID: x5000c0s0b0
      IPAddress: 10.100.0.50
      MACAddr: 05:00:00:00:00:00
      Password: ""
      RediscoverOnUpdate: true
      Type: NodeBMC
      UUID: 00000000-0000-0000-0000-000000000000
      User: MY_BMC_USER

# If the discovery just ran, it might take a moment until the information is
# synced to PCS

# check the BMC power status
[user@demo ~]$ ochami pcs status show x5000c0s0b0 
{"error":"","lastUpdated":"2026-08-21T07:51:52.35278Z","managementState":"available","powerState":"on","supportedPowerTransitions":["Soft-Restart"],"xname":"x5000c0s0b0"}

# check the node's power status - in this example it's currently off
[user@demo ~]$ ochami pcs status show x5000c0s0b0n0
{"error":"","lastUpdated":"2026-08-21T07:57:56.958534Z","managementState":"available","powerState":"off","supportedPowerTransitions":["On","Force-Off","Soft-Off","Off","Soft-Restart","Init","Hard-Restart"],"xname":"x5000c0s0b0n0"}

# (!) known issue that will be fixed soon: The supported power transitions here
# are given with mixed case letters, but a transition start command only works
# with all lower case letters.

# boot the node
[user@demo ~]$ ochami pcs transition start --xname x5000c0s0b0n0 on
{"TransitionID":"2d49b9fb-2f6c-4e9e-a8c8-6c0c6f9285c8","Operation":"On"}

# (!) just because the transition start command did not return an error does
# not mean the transition itself was successful. Always check or monitor.

[user@demo ~]$ ochami pcs transition show 2d49b9fb-2f6c-4e9e-a8c8-6c0c6f9285c8
{"automaticExpirationTime":"2026-08-22T08:14:01.010959Z","createTime":"2026-08-21T08:14:01.010959Z","operation":"On","taskCounts":{"failed":0,"in-progress":1,"new":0,"succeeded":0,"total":1,"un-supported":0},"tasks":[{"taskStatus":"in-progress","taskStatusDescription":"Confirming successful transition, on","xname":"x5000c0s0b0n0"}],"transitionID":"2d49b9fb-2f6c-4e9e-a8c8-6c0c6f9285c8","transitionStatus":"in-progress"}

[user@demo ~]$ ochami pcs transition monitor 2d49b9fb-2f6c-4e9e-a8c8-6c0c6f9285c8
new          [--------------------------------------------------------------] 0 %
in-progress  [--------------------------------------------------------------] 0 %
succeeded    [=============================================================>] 100 %
failed       [--------------------------------------------------------------] 0 %
```
