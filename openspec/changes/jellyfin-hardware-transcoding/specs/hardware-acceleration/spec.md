## Purpose

Define who owns a host hardware accelerator, how access to it is granted
through the compute boundary to media workloads, and how those workloads
behave, recover, and are verified when the accelerator is present or missing.

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

### Requirement: Accelerator grants are limited to media processing

An accelerator grant SHALL be given only to a workload whose declared purpose
is processing household media, such as transcoding, thumbnail, or preview
generation. Granting an accelerator to a workload with another purpose SHALL
require a change to this contract.

#### Scenario: A non-media workload requests the accelerator

- **WHEN** desired configuration grants the accelerator to a workload whose
  purpose is not media processing
- **THEN** the change is out of contract and needs a contract decision before
  it is accepted

### Requirement: Granted access is the render interface held through a stable group capability

A granted workload SHALL receive only the accelerator's unprivileged render
interface. It SHALL NOT receive display, modesetting, or device-management
interfaces of the accelerator. Access SHALL be held through membership in a
stable group capability dedicated to that accelerator access. The group's
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

### Requirement: Accelerator loss does not gate compute or unrelated workloads

A missing, unbound, or failed accelerator SHALL NOT prevent the compute domain,
its management and recovery services, or unrelated workloads from starting or
continuing. It SHALL NOT prevent a granted workload from starting.

#### Scenario: The compute domain starts without its accelerator

- **WHEN** the compute domain starts while the host accelerator is absent or
  its driver failed to load
- **THEN** the compute domain, its management path, and all workloads start,
  including granted workloads

#### Scenario: The accelerator returns

- **WHEN** the host accelerator becomes available again after it was absent
- **THEN** granted access is restored without replacing the compute domain

### Requirement: Playback transcoding falls back to software

When acceleration is unavailable or does not work, a media server's playback
transcoding SHALL continue in software rather than fail. Fallback SHALL take
effect no later than the next start of the media server. When acceleration
works again, the media server SHALL use it again no later than its next start.
Transcodes already running when the accelerator disappears MAY fail.

#### Scenario: The media server starts without working acceleration

- **WHEN** the media server starts and the accelerator is absent, cannot be
  opened, or fails a functional check
- **THEN** playback that needs transcoding uses software transcoding

#### Scenario: The media server starts with working acceleration

- **WHEN** the media server starts and the accelerator passes a functional
  check
- **THEN** playback transcoding uses the accelerator

#### Scenario: The accelerator fails while the media server is running

- **WHEN** the accelerator becomes unavailable while the media server is
  running
- **THEN** an affected transcode may fail, and the media server uses software
  transcoding after its next start

### Requirement: Degraded acceleration is observable

When a granted workload runs without acceleration it was granted, the
degraded state and its reason SHALL be visible in a declared, operator-visible
place. An operator SHALL NOT have to reproduce a failed or slow playback to
discover it.

#### Scenario: An operator checks acceleration state

- **WHEN** an operator follows the documented check for a granted workload
- **THEN** the check states whether the workload is using hardware or
  software, and why acceleration is not in use if it is not

#### Scenario: Fallback happens silently from the user's view

- **WHEN** the media server falls back to software transcoding
- **THEN** the fallback is recorded where the documented check finds it,
  even though playback continues

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
capability, and that a missing accelerator leaves the compute domain and the
media server running with software transcoding and a visible degraded state.

#### Scenario: Checks run on a machine without the accelerator

- **WHEN** repository checks run on a builder or virtual machine without the
  target accelerator
- **THEN** they verify grant scope, interface, group capability, and
  missing-accelerator behavior, using a stand-in device where a device is
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
