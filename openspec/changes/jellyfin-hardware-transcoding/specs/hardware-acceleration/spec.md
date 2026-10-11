## Purpose

Define who owns a host hardware accelerator, how access to it is granted
through the compute boundary to workloads the owner explicitly declares, and
how those workloads behave, recover, and are verified when the accelerator is
present or missing.

## ADDED Requirements

### Requirement: The physical host owns accelerator hardware, drivers, and firmware

The managed machine that holds a hardware accelerator SHALL own its device
identity, kernel driver selection, firmware, and driver lifecycle. A compute
domain or workload that is granted access SHALL NOT load or unload kernel
modules, change firmware, rebind the device to another driver, or reset the
device. The user-space media stack that drives the accelerator SHALL remain
owned by the workload's own release, not by the host.

#### Scenario: A workload is granted an accelerator

- **WHEN** a workload receives access to a host accelerator
- **THEN** it can submit work to the accelerator, but cannot change which
  driver or firmware the host uses for it

#### Scenario: Host driver or firmware changes

- **WHEN** the host's kernel, driver, or firmware for the accelerator changes
- **THEN** the change is made and reviewed as host configuration, and no guest
  or workload configuration has to change for the accelerator to keep working

### Requirement: Host access to the render interface is limited to declared users and granted guests

On the host that owns an accelerator, only host users declared in host
configuration and compute domains holding a declared grant SHALL be able to
open the accelerator's render interface. Any other host process SHALL NOT be
able to open it. Restricting host access SHALL NOT change the access of a
granted workload inside a compute domain.

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
grant from the host to the compute domain and a separate explicit grant from
the compute domain to each workload. A workload SHALL NOT obtain access
through its own configuration alone, and a compute-domain grant SHALL NOT by
itself give access to every workload in that domain.

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

A granted workload SHALL receive only the accelerator's unprivileged render
interface. It SHALL NOT receive display, modesetting, or device-management
interfaces of the accelerator. Access SHALL be held through membership in a
stable group capability dedicated to accelerator access. The group's
identity SHALL remain the same across compute replacement, and an identity
without the capability SHALL NOT be able to open the render interface even if
the interface is visible to it.

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

- **WHEN** the compute domain starts while the host accelerator is absent or
  its driver failed to load
- **THEN** the compute domain, its management path, and all workloads start,
  including granted workloads

#### Scenario: A granted media server serves playback without its accelerator

- **WHEN** the accelerator is unavailable and a client plays media that needs
  no transcode
- **THEN** playback succeeds

#### Scenario: The accelerator returns

- **WHEN** the host accelerator becomes available again after it was absent
- **THEN** granted access is restored without replacing the compute domain

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
