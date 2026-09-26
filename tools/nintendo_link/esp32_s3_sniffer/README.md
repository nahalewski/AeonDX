# ESP32-S3 LDN Sniffer

Receive-only diagnostic for Switch local-wireless advertisements. It listens
for 802.11 management frames on 2.4 GHz channels 1, 6, and 11 and counts
action frames containing Nintendo's `00:22:aa` OUI. It does not associate,
transmit, decrypt advertisements, or join a room.

The ESP32-S3 radio is 2.4 GHz only, so this cannot detect a room that is
advertising only on 5 GHz. Its first purpose is to distinguish a Switch-side
radio/channel issue from the Pixel's monitor receive path.

## Build and flash

Install ESP-IDF with the ESP32-S3 toolchain, then from this directory run:

```powershell
idf.py set-target esp32s3
idf.py build
idf.py -p COMx flash monitor
```

Replace `COMx` with the serial port assigned to the board. Keep Scarlet in
Poké Portal > Union Circle > Form a Group in Local Communication mode. The
serial monitor prints management-frame, action-frame, and Nintendo-OUI counts
once per channel dwell. Ordinary nearby access-point beacons should make the
management count nonzero on whichever scanned channel they use.