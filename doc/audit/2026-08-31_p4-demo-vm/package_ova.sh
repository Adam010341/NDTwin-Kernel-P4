#!/bin/bash
# Wrap the converted VMDK into an .ova, without ovftool (not installable here without a
# Broadcom account). An OVA is a tar of descriptor + manifest + disk, in that order -- the
# order is not cosmetic: an importer streams the archive and must read the descriptor before
# it reaches the disk.
#
# HARDWARE CHOICES, AND WHY THEY ARE THESE AND NOT THE USUAL ONES
#   SATA/AHCI, not the customary LSI Logic SCSI. The image was booted on an AHCI controller
#   on this machine and came up on /dev/sda1; it was NOT booted on a SCSI controller, and
#   qemu's LSI device is driven by a different kernel module (sym53c8xx) than VMware's LSI
#   Logic Parallel (mptspi), so testing it here would not have tested the thing that ships.
#   Shipping the controller that was actually verified is worth more than shipping the
#   conventional one.
#   E1000, likewise verified: the guest brought up ens3 and took a DHCP lease on it.
#   4 vCPU / 6144 MB are the settings every acceptance run in this build used. A smaller
#   memory figure would be a configuration nobody tested.
# [Co-developed with claude code -- Adam]
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="NDTwin-P4-demo"
VMDK="$DIR/${NAME}-disk1.vmdk"
OVF="$DIR/${NAME}.ovf"
MF="$DIR/${NAME}.mf"
OVA="$DIR/${NAME}.ova"

[ -f "$VMDK" ] || { echo "ABORT: $VMDK not found -- run the qemu-img convert first"; exit 1; }

# Parse the JSON, do not regex it. The sed version of this line returned 21437349888 -- the
# qcow2's actual-size -- and that number would have gone into ovf:capacity, telling VMware the
# 60 GiB filesystem lives on a 20 GB disk. It was caught only because the value happened to
# equal a file size I recognised; nothing in the script would have complained.
CAP=$(qemu-img info -U --output=json "$DIR/ndtwin-p4-demo-work.qcow2" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')
[ "$CAP" -gt 60000000000 ] || { echo "ABORT: capacity $CAP is implausible for a 60 GiB image"; exit 1; }
VMDK_SIZE=$(stat -c%s "$VMDK")
POP=$VMDK_SIZE
echo "  capacity:  $CAP bytes"
echo "  vmdk size: $VMDK_SIZE bytes"

cat > "$OVF" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
          xmlns:vmw="http://www.vmware.com/schema/ovf"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <References>
    <File ovf:href="${NAME}-disk1.vmdk" ovf:id="file1" ovf:size="${VMDK_SIZE}"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="${CAP}" ovf:capacityAllocationUnits="byte" ovf:diskId="vmdisk1"
          ovf:fileRef="file1"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"
          ovf:populatedSize="${POP}"/>
  </DiskSection>
  <NetworkSection>
    <Info>The list of logical networks</Info>
    <Network ovf:name="NAT">
      <Description>NAT network -- the guest takes a DHCP lease</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="${NAME}">
    <Info>NDTwin P4/BMv2 demo virtual machine</Info>
    <Name>${NAME}</Name>
    <OperatingSystemSection ovf:id="94" vmw:osType="ubuntu64Guest">
      <Info>The kind of installed guest operating system</Info>
      <Description>Ubuntu Linux 24.04 LTS (64-bit)</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${NAME}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-14</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of Virtual CPUs</rasd:Description>
        <rasd:ElementName>4 virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>4</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>6144MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>6144</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SATA Controller</rasd:Description>
        <rasd:ElementName>sataController0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>vmware.sata.ahci</rasd:ResourceSubType>
        <rasd:ResourceType>20</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>disk0</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>1</rasd:AddressOnParent>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>NAT</rasd:Connection>
        <rasd:Description>E1000 ethernet adapter</rasd:Description>
        <rasd:ElementName>ethernet0</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>E1000</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
    <AnnotationSection>
      <Info>A human-readable annotation</Info>
      <Annotation>NDTwin P4/BMv2 demo. Ubuntu 24.04.4 LTS with the NDTwin Kernel, Ryu, Mininet, OVS, p4c 1.2.5.16 and BMv2 1.15.5-fdd3b893 already built and installed. Logins: tester/tester (owns the installation, under ~/Desktop/NDTwin-Kernel) and ndtwin/ndtwin; root password ndtwin. Change all three before putting this VM on a network.</Annotation>
    </AnnotationSection>
  </VirtualSystem>
</Envelope>
EOF
echo "  wrote $(basename "$OVF")"

# The manifest covers the descriptor and the disk. An importer that checks it will reject a
# truncated download, which is the failure a multi-GB link makes most likely.
( cd "$DIR" && sha256sum "${NAME}.ovf" "${NAME}-disk1.vmdk" \
    | awk '{printf "SHA256(%s)= %s\n", $2, $1}' > "${NAME}.mf" )
echo "  wrote $(basename "$MF")"
sed 's/^/    /' "$MF"

# Order matters: descriptor, manifest, then disk.
( cd "$DIR" && tar -cf "${NAME}.ova" "${NAME}.ovf" "${NAME}.mf" "${NAME}-disk1.vmdk" )
echo "  wrote $(basename "$OVA")  ($(stat -c%s "$OVA") bytes)"
echo
echo "=== archive contents, in order ==="
tar -tvf "$OVA" | sed 's/^/  /'
