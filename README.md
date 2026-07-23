This project started as "set up a simple Flatcar install" to "Manage a Flatcar instance as code, so it can be destroyed and recreated at whim."

The script 'go.sh' in this repository does 3 things:
  - Creates `felix.yaml` from the `felix.template.yaml` and the `felix.secrets` file (a file not committed to the repo).
  - Transpiles `felix.yaml` into `felix.ign`
  - Launches a Flatcar live image using the `felix.ign` to provision it.

If you clone and use this repository, you may want to rename `felix`; but at a bare minimum you'll want to modify `felix.template.yaml` to match your secret names, and you'll want to create your own `felix.secrets` file. The syntax of the `felix.secrets` is just a simple declarate bash array:
```
# felix.secrets
declare -A SECRETS

SECRETS["ADGUARD_PASSWORD_HASH"]='$2a$12$4...'
SECRETS["ADGUARD_API_USER"]='dingus'
...
```

Note that I have some special things in the go.sh that starts the live image. The bare minimum command to start the live image is:
`./flatcar_production_qemu.sh -i felix.ign -nographic`

Note that ignition sequence is only run *the first time* the instance is provisioned: changes are made to the image file, and subsequent runs where you pass `-i felix.ign` do nothing. This is why there is a section in go.sh to delete the local live image and copy the vanilla flatcar image over.

To fetch a new Flatcar image run:

`wget -o flatcar_production_qemu_image.img.vanilla https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_qemu_image.img`

To test against this image you cannot use `sudo` unless you modify your sudo to set/keep some environment variables. I haven't figured out which ones yet. 

