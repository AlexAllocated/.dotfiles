{ ... }:
{
  services.pipewire.wireplumber.extraConfig."51-creator-hardware-aliases" = {
    "monitor.alsa.rules" = [
      {
        matches = [ { "device.name" = "~alsa_card[.]usb-ACTIONS_Pebble_V3.*"; } ];
        actions.update-props."api.alsa.soft-mixer" = true;
      }
      {
        matches = [
          {
            "node.name" = "~alsa_input[.]usb-Logitech_Yeti_2_.*-00[.]analog-stereo";
          }
        ];
        actions.update-props = {
          "node.name" = "creator.hardware.yeti-2.mic";
          "node.description" = "Yeti 2 Microphone";
          "node.nick" = "Yeti 2 Microphone";
        };
      }
      {
        matches = [
          {
            "node.name" = "~alsa_output[.]usb-Logitech_Yeti_2_.*-00[.]analog-stereo";
          }
        ];
        actions.update-props = {
          "node.name" = "creator.hardware.yeti-2.output";
          "node.description" = "Yeti 2 Headphones";
          "node.nick" = "Yeti 2 Headphones";
          "device.form-factor" = "headphones";
        };
      }
      {
        matches = [
          {
            "node.name" = "~alsa_output[.]usb-Generic_TX-Hifi_Type_C_Audio-.*[.]analog-stereo";
          }
        ];
        actions.update-props = {
          "node.name" = "creator.hardware.tx-hifi.output";
          "node.description" = "TX-Hifi Headphones";
          "node.nick" = "TX-Hifi Headphones";
        };
      }
      {
        matches = [
          {
            "node.name" = "~alsa_output[.]usb-ACTIONS_Pebble_V3-.*[.]analog-stereo";
          }
        ];
        actions.update-props = {
          "node.name" = "creator.hardware.pebble-v3.output";
          "node.description" = "Pebble V3 Speakers";
          "node.nick" = "Pebble V3 Speakers";
        };
      }
    ];
  };

  services.pipewire.wireplumber.extraConfig."52-creator-bluetooth-headsets" = {
    "wireplumber.settings" = {
      "bluetooth.autoswitch-to-headset-profile" = true;
      "bluetooth.use-persistent-storage" = true;
    };
    "monitor.bluez.properties" = {
      "bluez5.enable-msbc" = true;
    };
  };

}
