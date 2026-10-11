## Purpose

Define who owns a host hardware accelerator and who drives it, how access to
it or to a share of it is granted through the compute boundary to workloads
the owner explicitly declares, and how those workloads behave, recover, and
are verified when the accelerator is present or missing. The contract applies
whether a compute domain is a container or a virtual machine.

## ADDED Requirements

### Requirement: The owner declares which domain drives an accelerator or each share of it

The managed machine that holds a hardware accelerator SHALL own the physical
device and its partitioning: whether the device is divided into shares, such
as mediated devices or virtual functions, and which share is attached to which
compute domain. For the physical device and for each share, desired
configuration SHALL declare the driving domain: the host, or the one compute
domain that holds that share or the whole device. Only the declared driving
domain SHALL select the kernel driver, and any firmware that driver loads, for
what it drives. A compute domain SHALL NOT drive, reset, rebind, or
repartition anything beyond what is granted to it. A workload SHALL NOT load
or unload kernel modules, change firmware, rebind, or reset the device or any
share. The user-space media stack SHALL remain owned by the workload's own
release.

#### Scenario: The host drives the device for a compute domain

- **WHEN** the host is the declared driving domain and a compute domain is
  granted access
- **THEN** the host selects the driver and firmware, and the compute domain
  and its workloads use the accelerator only through the interface granted to
  them

#### Scenario: A compute domain drives its granted share

- **WHEN** a compute domain is the declared driving domain for a share or for
  the whole device
- **THEN** it selects the driver and firmware for that share only, and it
  cannot change the physical device's partitioning or any other share

#### Scenario: A workload is granted an accelerator

- **WHEN** a workload receives access to an accelerator
- **THEN** it can submit work to the accelerator, but cannot change which
  driver or firmware is used for it

#### Scenario: Driver or firmware changes

- **WHEN** the kernel, driver, or firmware for an accelerator or share changes
- **THEN** the change is made and reviewed in the configuration of its
  declared driving domain, and no workload configuration has to change for
  the accelerator to keep working

### Requirement: Accelerator sharing is optional and bounded by explicit grants

One physical accelerator MAY be shared among the host and several compute
domains, or MAY be given whole to one domain. This contract SHALL NOT require
either arrangement. Each share and each whole-device attachment SHALL be
granted explicitly in desired configuration. Several domains MAY be granted
the same host-driven render interface. No grant SHALL reach beyond its share:
a domain or workload SHALL NOT be able to use a share or interface granted
only to another domain, or change the device's partitioning.

#### Scenario: One accelerator is shared

- **WHEN** desired configuration shares one accelerator among the host and
  several compute domains
- **THEN** each domain can use only the share granted to it, and the
  arrangement is identifiable from the repository

#### Scenario: One domain takes the whole accelerator

- **WHEN** desired configuration gives the whole accelerator to one compute
  domain
- **THEN** the host and other domains lose access to it, and that loss is
  declared rather than incidental

#### Scenario: A grant reaches beyond its share

- **WHEN** a configuration would let a domain or workload use more than its
  declared share
- **THEN** the configuration is rejected, or the running state is reported as
  drift

### Requirement: Host access to a host-driven render interface is limited to declared users and granted guests

Where the host drives an accelerator or a share of it, only host users
declared in host configuration and compute domains holding a declared grant
SHALL be able to open its render interface. No other unprivileged host
process SHALL be able to open it. Restricting host access SHALL NOT change the
access of a granted workload inside a compute domain.

#### Scenario: An undeclared host process opens the render interface

- **WHEN** an unprivileged host process whose user is not declared for
  accelerator access tries to open the render interface
- **THEN** the open is denied

#### Scenario: A declared host user opens the render interface

- **WHEN** a host process runs as a user that host configuration declares for
  accelerator access
- **THEN** it can open the render interface

#### Scenario: Host access is restricted while a guest holds a grant

- **WHEN** host access to the render interface is restricted to declared
  users
- **THEN** a granted workload in a granted compute domain can still open the
  render interface through its grant

### Requirement: Accelerator access requires an explicit grant at each boundary

Access to a host accelerator SHALL require an explicit, repository-declared
grant of the device, a share of it, or its render interface from the host to
the compute domain, and a separate explicit grant from the compute domain to
each workload. A workload SHALL NOT obtain access through its own
configuration alone, and a compute-domain grant SHALL NOT by itself give
access to every workload in that domain.

#### Scenario: An ungranted workload runs in a granted compute domain

- **WHEN** a workload without a declared accelerator grant runs in a compute
  domain that holds one
- **THEN** the workload cannot open the accelerator

#### Scenario: Grants are reviewed

- **WHEN** a maintainer reviews desired configuration
- **THEN** every compute domain and every workload that can use an
  accelerator is identifiable from the repository without inspecting a running
  system

#### Scenario: An undeclared grant appears at runtime

- **WHEN** a running compute instance carries an accelerator attachment that
  desired configuration does not declare
- **THEN** compute lifecycle operations report the drift and do not treat the
  instance as conformant

### Requirement: Only workloads the owner explicitly declares are eligible for a grant

An accelerator grant SHALL be given only to a workload that the owner
explicitly declares as a grant holder in repository configuration. Eligibility
SHALL NOT be implied by a workload's category, purpose, namespace, label, or
image. Any workload may receive a grant once the owner declares it, without a
change to this contract.

#### Scenario: A workload is not declared as a grant holder

- **WHEN** a workload that the owner has not declared as a grant holder asks
  for the accelerator, for example by mounting device paths or claiming the
  capability group
- **THEN** desired configuration is rejected and the workload receives no
  access

#### Scenario: The owner declares a new grant holder

- **WHEN** the owner declares an additional workload as a grant holder
- **THEN** that workload receives access through the same grant path and
  interface rules, and no contract change is needed

### Requirement: Granted access is the render interface held through a stable group capability

A granted workload SHALL receive only the unprivileged render interface of
the accelerator or share granted to its compute domain. It SHALL NOT receive
display, modesetting, or device-management interfaces. Access SHALL be held
through membership in a stable group capability dedicated to accelerator
access. Inside a compute domain, the render interface SHALL carry that group
and the same permissions whether the domain receives the interface from the
host or creates it through its own driver. The group's identity SHALL remain
the same across compute replacement and across a change in how the domain
obtains the interface. An identity without the capability SHALL NOT be able
to open the render interface even if the interface is visible to it.

#### Scenario: A granted workload opens the accelerator

- **WHEN** a granted workload running as its own non-root identity opens the
  render interface
- **THEN** the open succeeds because the workload holds the accelerator
  capability, not because it runs as root or as the device owner

#### Scenario: An identity without the capability sees the device

- **WHEN** a process without the accelerator capability can see the render
  interface
- **THEN** it cannot open the interface

#### Scenario: A granted workload looks for display interfaces

- **WHEN** a granted workload lists the accelerator interfaces available to it
- **THEN** only the render interface is present

#### Scenario: The compute domain drives its own share

- **WHEN** a compute domain creates the render interface through its own
  driver instead of receiving it from the host
- **THEN** the interface carries the same group capability and permissions,
  and granted workloads need no change to keep access

### Requirement: Accelerator access does not weaken compute isolation

Delegating an accelerator SHALL NOT require a privileged compute domain, a
privileged workload, host-root identity mappings, added kernel capabilities,
access to host management sockets, or access to unrelated host devices. A
configuration that would need any of these to make acceleration work SHALL be
rejected rather than enabled.

#### Scenario: Acceleration needs more authority than declared

- **WHEN** a workload's acceleration fails unless it gains privilege, extra
  capabilities, or broader device access
- **THEN** the workload does not gain that authority, and the failure is
  handled as accelerator unavailability

### Requirement: Accelerator loss affects only accelerated work

A missing, unbound, or failed accelerator SHALL NOT prevent the compute domain,
its management and recovery services, or unrelated workloads from starting or
continuing. It SHALL NOT prevent a granted workload from starting or from
serving work that does not use the accelerator. Only work that uses the
accelerator MAY fail.

#### Scenario: The compute domain starts without its accelerator

- **WHEN** the compute domain starts while the accelerator or its share is
  absent, or the driver in its driving domain failed to load
- **THEN** the compute domain, its management path, and all workloads start,
  including granted workloads

#### Scenario: A granted media server serves playback without its accelerator

- **WHEN** the accelerator is unavailable and a client plays media that needs
  no transcode
- **THEN** playback succeeds

#### Scenario: The accelerator returns

- **WHEN** the accelerator becomes available again after it was absent
- **THEN** granted access is restored without replacing the compute domain or
  changing configuration; a restart of the compute domain or the workload MAY
  be needed where the attachment cannot be added while it runs

### Requirement: Transcoding mode is declared and accelerator failure is not hidden

A granted media server's transcoding mode, hardware or software, SHALL be
declared in repository configuration and applied through the media server's
declared settings owner. The mode SHALL NOT change automatically at runtime.
When hardware mode is declared and the accelerator is missing or does not
work, transcodes that need it SHALL fail with an error rather than switch to
software silently. Switching to software SHALL be a declared configuration
change made by an operator. When the accelerator works again and hardware mode
is still declared, hardware transcoding SHALL resume no later than the media
server's next start, without a configuration change.

#### Scenario: Hardware mode is declared and the accelerator works

- **WHEN** hardware mode is declared and a client plays media that needs a
  transcode
- **THEN** the transcode uses the accelerator

#### Scenario: Hardware mode is declared and the accelerator is unavailable

- **WHEN** hardware mode is declared, the accelerator is absent, cannot be
  opened, or fails, and a client plays media that needs a transcode
- **THEN** the transcode fails with an error visible to the client and in the
  media server's logs, and the declared mode does not change

#### Scenario: An operator switches to software

- **WHEN** an operator changes the declared mode to software and the change is
  applied
- **THEN** transcodes use software, and the media server does not try the
  accelerator

#### Scenario: The accelerator returns while hardware mode is declared

- **WHEN** the accelerator becomes available again and hardware mode is still
  declared
- **THEN** hardware transcoding works again no later than the media server's
  next start, with no configuration change

### Requirement: Degraded acceleration is detectable

When hardware mode is declared for a granted workload and the accelerator is
not usable by that workload, an operator SHALL be able to detect it with a
documented check. The check SHALL NOT require reproducing a failed playback,
and it SHALL state whether the workload can open and use the accelerator and,
if not, why. A workload that is declared to run in software mode SHALL be
reported as running in software by declaration, not as degraded.

#### Scenario: An operator checks acceleration state

- **WHEN** an operator follows the documented check for a granted workload
- **THEN** the check states the declared mode, whether the workload can open
  and use the accelerator, and the reason if it cannot

#### Scenario: The accelerator is lost before anyone plays media

- **WHEN** the accelerator becomes unavailable while hardware mode is declared
  and no transcode has been attempted
- **THEN** the documented check reports the degraded state

#### Scenario: Software mode is declared

- **WHEN** an operator runs the documented check while software mode is
  declared
- **THEN** the check reports software by declaration and does not report a
  fault

### Requirement: Replacement compute regains declared accelerator grants

A replaced or recreated compute domain SHALL regain its declared accelerator
grants, and granted workloads SHALL regain access, from repository-declared
configuration alone. Recovery SHALL NOT require manual device creation,
manual permission changes, or restoring a previous compute instance root.

#### Scenario: The compute domain is replaced

- **WHEN** an operator replaces the compute instance through the declared
  replacement procedure
- **THEN** the replacement receives the same accelerator grant, and granted
  workloads can use the accelerator without manual device setup

### Requirement: Accelerator delegation is verifiable without the target hardware

The grant, scope, isolation, and failure behavior of accelerator delegation
SHALL be verifiable by repository checks that do not need the target
accelerator. These checks SHALL cover that only declared workloads receive
access, that access is the render interface held through the group
capability, that host access is limited to declared users and granted guests,
and that a missing accelerator leaves the compute domain and the granted
workload running with the declared mode unchanged and the degraded state
reported by the documented check.

#### Scenario: Checks run on a machine without the accelerator

- **WHEN** repository checks run on a builder or virtual machine without the
  target accelerator
- **THEN** they verify grant scope, interface, group capability, host access,
  and missing-accelerator behavior, using a stand-in device where a device is
  needed

### Requirement: Hardware acceleration is accepted only on the target hardware

Hardware-accelerated transcoding SHALL be reported as accepted only after an
operator-run acceptance on the target host shows a real transcode using the
accelerator. Results from stand-in devices or evaluation SHALL NOT be reported
as hardware acceleration.

#### Scenario: Stand-in checks pass

- **WHEN** repository checks pass using a stand-in device
- **THEN** the result is recorded as plumbing evidence, not as hardware
  acceleration acceptance

#### Scenario: Operator acceptance on the target host

- **WHEN** an operator plays media that forces a transcode on the target host
- **THEN** acceptance requires evidence that the accelerator's media engine
  did the work and that the workload stayed within its declared resources
