# LMS-Bluetooth

This is both a lyrion plugin and a PiCorePlayer bridge that allows management, connection and allocation of bluetooth devices discovered by the PcP computer.  It allows the virtual attribution of a bluetooth remote control to an audio endpoint, the automatic configuration of a bluetooth speaker as a Lyrion endpoint, the control of BluetoothLE subwoofers (Martin Logan / Paradigm / SVS (untested)) and low latency bluetooth audio transfer to any LMS endpoint resulting in synced A/V.  
The bridge is controllable from
within the Lyrion interface.
Many such bridges can be run on the network and the Lyrion plugin will auto-detect these.

Version 0.2.1.

[Lire en français](#français)

## Lyrion repository

In Settings → Plugins → additional repositories, add:

https://raw.githubusercontent.com/jsarcand/LMS-bluetooth/main/repo.xml

Lyrion downloads `Bluetooth-0.2.1.zip` and checks its SHA1. The archive contains a `Bluetooth/` folder with `install.xml` at the plugin root.

The player menu can read the page with `bluetooth page noscan:1`. That returns the known cards and does not scan. The Bluetooth menu itself still scans. Identity lookups and subwoofer reads run in another process, so they do not freeze Lyrion.

Extras → Bluetooth, on a player, lists the inputs linked to that player. Choosing one starts it. The same menu groups that player's drift and subwoofer settings. The plugin's own settings page edits the registry without Material.

## piCorePlayer

The extension is `pcp/lms-bluetooth.tcz` (gzip, 16K blocks, the same as the other extensions on piCorePlayer 11). Copy these three files into the tce optional directory (`/etc/sysconfig/tcedir/optional`):

- `lms-bluetooth.tcz`
- `lms-bluetooth.tcz.md5.txt`
- `lms-bluetooth.tcz.dep`

Add `lms-bluetooth.tcz` to `onboot.lst` if it should load at every boot. Load it with `tce-load -i lms-bluetooth`, or reboot. The extension copies the plugin into both Lyrion cache trees. It does not restart Lyrion and it does not start playback. Restart Lyrion once so the new files are loaded.

`lms-bluetooth.tcz.dep` asks for `slimserver.tcz`, `python3.11.tcz`, `python3.11-bleak.tcz`, `dbus-python3.11.tcz`, `pcp-bt.tcz`, and `bluez-alsa.tcz`.

## Français

Plugin Lyrion. Il tient le registre des dispositifs Bluetooth, de leur platine et du drift. Le bridge est prévenu ensuite. Rien ne se met à jouer.

Version 0.2.1.

### Dépôt Lyrion

Dans Réglages → Greffons → dépôts supplémentaires :

https://raw.githubusercontent.com/jsarcand/LMS-bluetooth/main/repo.xml

Lyrion télécharge `Bluetooth-0.2.1.zip` et vérifie son SHA1. L’archive contient un dossier `Bluetooth/` avec `install.xml` à la racine du plugin.

Le menu de la platine peut lire la page avec `bluetooth page noscan:1`. Cela renvoie les cartes déjà connues, sans balayage. Le menu Bluetooth lui-même balaie encore. Les lectures d’identité et du caisson tournent dans un autre processus, donc elles ne figent pas Lyrion.

Extras → Bluetooth, sur une platine, liste les entrées liées à cette platine. L’appui en démarre une. Le même menu regroupe le drift et les réglages du caisson de cette platine. La page de réglages du plugin édite le registre sans Material.

### piCorePlayer

L’extension est `pcp/lms-bluetooth.tcz` (gzip, blocs de 16K, comme les autres extensions de piCorePlayer 11). Copier ces trois fichiers dans le dossier optional de tce (`/etc/sysconfig/tcedir/optional`) :

- `lms-bluetooth.tcz`
- `lms-bluetooth.tcz.md5.txt`
- `lms-bluetooth.tcz.dep`

Ajouter `lms-bluetooth.tcz` à `onboot.lst` si l’extension doit se charger à chaque démarrage. La charger avec `tce-load -i lms-bluetooth`, ou redémarrer. L’extension copie le plugin dans les deux arbres de cache de Lyrion. Elle ne relance pas Lyrion et ne démarre aucune lecture. Relancer Lyrion une fois pour prendre les nouveaux fichiers.

`lms-bluetooth.tcz.dep` demande `slimserver.tcz`, `python3.11.tcz`, `python3.11-bleak.tcz`, `dbus-python3.11.tcz`, `pcp-bt.tcz` et `bluez-alsa.tcz`.
