# Install Notes

Date: 2023-03-31
Machine: ThinkPad T14s Gen3 AMD
OS: Debian 12 (Bookworm, Testing)

- I could not install via the automated installing script from displaylink-debian
   - The autoinstall of EVDI failed
- I could not manually install EVDI from the GitHub source
   - Could not find the `drm.h` header to include
- I was able to manually install EVDI from the GitHub source by adding a symlink
to `/usr/include/libdrm` in the module directory so `drm.h` would be found
- After the above, neither the diplaylink-debian or DisplayLink install scripts
would work.
   - The `DisplayLink::displaylink-installer.sh` script (which is also called by
   `displaylink-debian::displaylink-debian.sh`) forced installation of its bundled
   version of EVDI (v1.12.0) which contained the same includes bug from above.
   - I was able to trick the script into running by replacing the bundled
   evdi.tar.gz with one containing the source for my successful install.
      - I think this works because `diplaylink-installer.sh` gets the EVDI version
      number from the `modules/dkms.conf` file in the bundled tarball.
      - This number is then supplied to `dkms install` to check if the correct
      version of EVDI is already installed.
      - If the correct version of EVDI is installed, the forced EVDI install is
      aborted and the rest of the script executes successfully.

## Steps

### EVDI

1. Clone EVDI source from <https://github.com/DisplayLink/evdi>.
1. Add symlink `evdi/module/drm.h -> /usr/include/libdrm/drm.h`
1. Build the EVDI DKMS module
   a. dkms add evdi/1.13.1
   a. dkms build evdi/1.13.1
   a. dkms install evdi/1.13.1

### DisplayLink Driver

1. Download the Ubuntu driver package from
<https://www.synaptics.com/products/displaylink-graphics/downloads/ubuntu>
1. Extract the driver components via
`./displaylink-driver-5.16.1.run --noexec --keep
1. Replace `displaylink-driver-5.16.1/evdi.tar.gz` with a version
containing the newer files from above
1. Run `displaylink-driver-5.16.1/displaylink-installer.sh`.

# Licensing Note

The MIT license attached to this repository applies only to my contributions.
The DisplayLink driver components are subject to the licensing terms applied
by synaptics (which are not clear to me).