---
layout: post
title:  "Golang: Reverse engineering an AKAI MPD26 using gousb"
date:   2019-01-30
tags: golang usb akai mpd26 reverse engineering
---

### Introduction

The other day, I discovered [Google's gousb](https://github.com/google/gousb) package. A low level interface for interacting with USB devices in Golang. At the time of writing, it's fairly one-of-a-kind. I haven't seen many golang packages attempt to tackle interfacing with USB devices and was keen to give it a try.

I perused the pile of dead tech sitting around my flat. After some solid thought, I decided to reverse engineer an old [AKAI MPD26](http://www.akaipro.com/products/legacy/mpd-26) sampler. These things were a super popular choice back when they were first released. Nowadays, there are far fancier samplers available which much more feature-rich interfaces. Unfortunately, I never really got deep into creating electronic music/getting good at using a sampler. This seemed like a way to make it a worthwhile purchase.

To start, lets examine the different parts of the sampler we want to be able to read from. It provides:

* 6 faders, these are used for things like managing volume of various channels. You would assign these to something in your DAW that they can manipulate.
* 6 knobs, these are more for manipulating automation that you've applied to audio tracks, but could easily also be used like a fader and vice versa
* 16 pressure sensitive pads, these are used to trigger the sounds you want to hear.

It's a fairly simple setup. There are a lot more buttons and knobs that modify the output of the aforementioned controls. For example, a 'note repeat' button which will cause pads to keep triggering if pressure is maintained on them.

I decided to set out some goals for how I'd like my interface to the sampler to work:

1. I want to implement it in Golang
2. It should provide a way to read values from individual aspects of the sampler using channels
3. It should abstract away as much of the nastiness of interfacing with USB devices as possible

### Connecting to the USB interface

For honesty, I had never done any programming work related to USB devices before, so I didn't really know what I was getting myself in to. Luckily, the gousb library provides a really simple interface. However, it requires some background reading on how connections with USB devices work.

The [godoc page](https://godoc.org/github.com/google/gousb) for the library has a pretty good explanation of how it works under the hood. I wish I'd read it first before trying to bruteforce my way in.

#### Figuring out which USB device to use

First challenge is figuring out which of the USB ports on the host machine is actually connected to the sampler. To do this, we need to know the product and vendor identifiers for the usb device.

[This question](https://electronics.stackexchange.com/questions/80815/what-is-a-product-id-in-usb-and-do-i-need-to-buy-it-for-my-project) on stack overflow has a good explanation of what these identifiers are:

> The Vendor ID or VID is a 16-bit number which you have to buy from the USB Foundation. If you want to make USB device (and fully play by the rules) the VID identifies your organisation.

> The Product ID or PID is also a 16-bit number but is under your control. When you purchase a VID you have the right to use that with every possible PID so this gives you 65536 possible VID:PID combinations. The intention is that a VID:PID combination should uniquely identify a particular poduct globally.

The AKAI MPD26 will already have a product and vendor identifier, so how do we find those? It's actually fairly simple if you use the `lsusb` command on UNIX systems. After plugging in the device, I was able to locate it pretty easy.

```bash
 > lsusb -v
```

Using this command, I was able to determine the product and vendor identifiers: `0x0078` and `0x09e8`. Using these, we can use the `gousb.Context.OpenDevices()` method. This method takes an argument of `func(desc *gousb.DeviceDesc) bool`. For each connected USB device, the provided method is executed and should return `true` if we've found a device we're interested in accessing.

```go
const (
  product = 0x0078
  vendor  = 0x09e8
)

func example() {
  ctx := gousb.NewContext()
  devices, _ := ctx.OpenDevices(findMPD26(product, vendor))

  // Do something with the device.
}

func findMPD26(product, vendor uint16) func(desc *gousb.DeviceDesc) bool {
  return func(desc *gousb.DeviceDesc) bool {
    return desc.Product == gousb.ID(product) && desc.Vendor == gousb.ID(vendor)
  }
}
```

Using this code, we get back an array of devices with one element, the sampler!

### Reading from the USB device

When dealing with a USB device, we need to obtain three things: a configuration, an interface and an endpoint.

The library defines USB configuration as:

>A config descriptor determines the list of available USB interfaces on the device.

Interfaces are defined too:

>Each interface is a virtual device within the physical USB device and its active config. There can be many interfaces active concurrently. Interfaces are enumerated sequentially starting from zero.

And finally, endpoints:

>An endpoint can be considered similar to a UDP/IP port, except the data transfers are unidirectional.

What we're after is that endpoint, that is where we will be able to read data from the device and react to it. To get it, we need to figure out the correct configuration, obtain the interface and then the endpoint.

My first attempt at connecting to the USB device failed for a couple of reasons. I tried to use some of the convenience methods available in the `gousb` library. Mainly, the `DefaultInterface` and `ActiveConfigNum` methods.

Here's the documentation for `DefaultInterface`:

>DefaultInterface opens interface #0 with alternate setting #0 of the currently active config. It's intended as a shortcut for devices that have the simplest interface of a single config, interface and alternate setting. The done func should be called to release the claimed interface and config.

And `ActiveConfigNum`:

>ActiveConfigNum returns the config id of the active configuration. The value corresponds to the ConfigInfo.Config field of one of the ConfigInfos of this Device.

`DefaultInterface` should allow you to skip finding an appropriate configuration so you can just get straight to your desired endpoint. I'm not sure if it's something to do with my machine, or the device itself, but this would return an error for me each time. I had the same issue with the `ActiveConfigNum` method.

However, when trying to connect to the device, I'd get the following error:

```bash
libusb: device or resource busy [code -6]
```

This is because the kernel has already assigned a driver to the USB device. In this case, `pulseaudio` was claiming the USB device as soon as it was plugged in since its an audio interface. I was able to debug this using the `journalctl` command while reconnecting the USB device.

This command is used to view `Systemd` logs and should let us know what is happening to our USB device whenever it is plugged in. Using the `-f` flag allows us to just read the most recent logs in real time. From this, I found that the `pulseaudio` driver would claim the device as soon as it was plugged in, so we can't use it!

The fix is nice and easy, the `gousb` library provides a method on the `Device` type called `SetAutoDetach` that will take the device away from `pulseaudio`.

>SetAutoDetach enables/disables automatic kernel driver detachment. When autodetach is enabled gousb will automatically detach the kernel driver on the interface and reattach it when releasing the interface. Automatic kernel driver detachment is disabled on newly opened device handles by default.

```go
const (
  product = 0x0078
  vendor  = 0x09e8
)

func example() {
  ctx := gousb.NewContext()
  devices, _ := ctx.OpenDevices(findMPD26(product, vendor))

  // Detach the device from whichever process already
  // has it.
  devices[0].SetAutoDetach(true)
}

func findMPD26(product, vendor uint16) func(desc *gousb.DeviceDesc) bool {
  return func(desc *gousb.DeviceDesc) bool {
    return desc.Product == gousb.ID(product) && desc.Vendor == gousb.ID(vendor)
  }
}
```

The next issue I faced was in the `ActiveConfigNum` and `DefaultInterface` methods. The configuration that the USB device was using would not allow me to use these methods. This means we have to make our own decisions on which config and interface to use.

To work around this, I decided to manually loop through configurations, then available interfaces. Once we get an interface we can use, we find the `IN` endpoint we can read from.

This code is a little bit ugly and I have excluded the error handling code for brevity. I'm sure there's a nicer way of doing this but for the sake of learning it serves its purpose:

```go
// Iterate through configurations
for num := range devices[0].Desc.Configs {
  config, _ := devices[0].Config(num)

  // In a scenario where we have an error, we can continue
  // to the next config. Same is true for interfaces and
  // endpoints.
  defer config.Close()

  // Iterate through available interfaces for this configuration
  for _, desc := range config.Desc.Interfaces {
    intf, _ := config.Interface(desc.Number, 0)

    // Iterate through endpoints available for this interface.
    for _, endpointDesc := range intf.Setting.Endpoints {
      // We only want to read, so we're looking for IN endpoints.
      if endpointDesc.Direction == gousb.EndpointDirectionIn {
        endpoint, _ := intf.InEndpoint(endpointDesc.Number)

        // When we get here, we have an endpoint where we can
        // read data from the USB device
      }
    }
  }
}
```

To stitch this all together we need a type that can hold all the contextual information about the USB device we're interacting with. This is the aptly named `MPD26` type:

```go
type MPD26 struct {
  // Fields for interacting with the USB connection
  context  *gousb.Context
  device   *gousb.Device
  intf     *gousb.Interface
  endpoint *gousb.InEndpoint

  // Additional fields we'll get to later
}
```

What we need now is a method that will constantly read from the endpoint and write values to channels. I've created an unexported method named `read` that runs an infinite loop in its own goroutine once the connection to the USB device is successful. Once again, error handling is redacted for clarity.

```go
func (mpd *MPD26) read(interval time.Duration, maxSize int) {
  ticker := time.NewTicker(interval)
  defer ticker.Stop()

  for {
    select {
    case <-ticker.C:
      buff := make([]byte, maxSize)
      n, _ := mpd.endpoint.Read(buff)

      data := buff[:n]
      // Do something with this data
    }
  }
}
```

You'll notice this method takes in two paramters, `interval` and `maxSize`. The `interval` parameter determines how often we should be attempting to read data from the USB device. It's important to note that calling the `mpd.endpoint.Read` method halts further execution if there's no data to read, so using this interval just ensures we don't read too often from the device. The `maxSize` parameter determines the maximum size of the buffer we should use when reading data. Both of these values can be obtained from the device configuration we looked at earlier:

```go
mpd := &MPD26{
  context:   ctx,
  device:    devices[0],
  intf:      intf,
  endpoint:  endpoint,
}

// The endpoint description defines the poll interval and max packet
// size.
go mpd.read(endpointDesc.PollInterval, endpointDesc.MaxPacketSize)
```

To start with, lets just print the contents of the byte array to `stdout` so that we can see the difference in values based on the controls we're using. Below are some samples:

```bash
[11, 176, 1, 127]  # Output when moving the first fader
[11, 176, 11, 127] # Output when moving the first knob
[9, 144, 36, 127]  # Output when triggering a pad
[8, 144, 26, 0]    # Output when releasing a pad
```

### Reverse engineering serial data

We're going to use the output we get reading the raw USB data to make some assumptions about which values mean what. Luckily, the values we're getting are MIDI. So any variance between 0-127 is usually a good candidate for the value of the control you're looking at. Based on the console output, it seems that the last byte in the array is always the MIDI value of the control.

This means the first 3 bytes should indicate the control we're using. I've still yet to figure out what all bytes in the array represent, but there are consistent values for certain controls, so we can use these to update the respective state of a control in the library.

#### Faders & Knobs

The faders and knobs were the easiest controls to get working. They only have a number to identify them and a value between 0 and 127. After playing with all of them, the first two bytes are consistently `[11, 176]`. We can use this information to create a method to identify if a message is for the value of a control:

```go
func isControl(data []byte) bool {
  // Knobs and faders all share the same two bytes in common, first and second
  // are always 11 and 176
  return data[0] == 11 && data[1] == 176
}
```

Easy enough. The next challenge is to determine if we're handling the change of a knob or a fader. This can be determined using the third byte in the array, which contains values from 1 to 6 for faders and 11 to 16 for the knobs. Using these, we can create two new helper methods to identify the types of control we're getting a message for:

```go
func isFader(data []byte) bool {
  // A fader is a control where the value of the third byte is always
  // 1 to 6
  return isControl(data) && data[2] >= 1 && data[2] <= 6
}

func isKnob(data []byte) bool {
  // A knob is a control where the value of the third byte is always
  // 11 to 16
  return isControl(data) && data[2] >= 11 && data[2] <= 16
}
```

#### Pads

The pads have a little more logic to them, but work the same way. The first byte determines whether or not the pad has been pressed or released, the second byte is always 144 and the third byte is a number between 26 and 51 that identifies the unique pad being pressed/released. Here's our method:

```go
func isPad(data []byte) bool {
 return (data[0] == 9 || data[0] == 8) && data[1] == 144 && (data[2] >= 36 && data[2] <= 51)
}
```

### Creating the Golang API

Now we need to expose this data in a nice way so that people can build things in Go using an MPD26. Earlier we saw code for reading the serial data, but we need a way to get that data out in a format that would make sense to someone looking directly at the sampler. We also want things to work asynchronously, waiting to read from a pad shouldn't block a read from a fader. 

For the asynchronous output, we're going to use channels, I've added the following fields to the `MPD26` type:

```go
// Channels for various components
faders map[int]chan int
knobs  map[int]chan int
pads   map[int]chan int
```

I've also updated the `read` method to make a call to a `paseMessage` function that classifies the type of input and writes to the correct channel:

```go
func (mpd *MPD26) parseMessage(msg []byte) {
 defer mpd.waitGroup.Done()

 // Discard invalid messages.
 if len(msg) < 4 {
  return
 }

 mpd.waitGroup.Add(1)

 if isFader(msg) {
  go mpd.handleFader(msg)
  return
 }

 if isKnob(msg) {
  go mpd.handleKnob(msg)
  return
 }

 if isPad(msg) {
  go mpd.handlePad(msg)
 }
}
```

As you can see, we now have 3 more functions for handling each kind of input `handlePad`, `handleKnob` and `handleFader`:

```go
func (mpd *MPD26) handlePad(data []byte) {
 defer mpd.waitGroup.Done()

 num := int(data[2]) - 35
 val := int(data[3])

 channel, ok := mpd.pads[num]

 if !ok {
  return
 }

 channel <- val
}

func (mpd *MPD26) handleKnob(data []byte) {
 defer mpd.waitGroup.Done()

 var num int
 val := int(data[3])

 switch data[2] {
 case 12:
  num = 6
 case 11:
  num = 5
 case 14:
  num = 4
 case 13:
  num = 3
 case 16:
  num = 2
 case 15:
  num = 1
 default:
  return
 }

 // Check if there's a channel already listening
 // to this knob, if so, write to it. Otherwise
 // ignore the message.
 channel, ok := mpd.knobs[num]

 if !ok {
  return
 }

 channel <- val
}

func (mpd *MPD26) handleFader(data []byte) {
 defer mpd.waitGroup.Done()

 num := int(data[2])
 val := int(data[3])

 // Check if there's a channel already listening
 // to this fader, if so, write to it. Otherwise
 // ignore the message.
 channel, ok := mpd.faders[num]

 if !ok {
  return
 }

 channel <- val
}
```

Now, we just need some exported functions on the `MPD26` type that someone can use to get the pad/fader/knob they want to read from:

```go
func (mpd *MPD26) Fader(id int) <-chan int {
	channel, ok := mpd.faders[id]

	if !ok {
		channel = make(chan int)
		mpd.faders[id] = channel
	}

	return channel
}

func (mpd *MPD26) Pad(id int) <-chan int {
	channel, ok := mpd.pads[id]

	if !ok {
		channel = make(chan int)
		mpd.pads[id] = channel
	}

	return channel
}

func (mpd *MPD26) Knob(id int) <-chan int {
	channel, ok := mpd.knobs[id]

	if !ok {
		channel = make(chan int)
		mpd.knobs[id] = channel
	}

	return channel
}
```

With all these in place, we can now connect and read from the sampler. In future, I'd like to hook this up to an audio library like [beep](https://github.com/faiface/beep) in order to get some actual output. But for now, we've got a working interface with the sampler!

### Links

* [https://github.com/google/gousb](https://github.com/google/gousb)
* [http://www.akaipro.com/products/legacy/mpd-26](http://www.akaipro.com/products/legacy/mpd-26)
* [https://electronics.stackexchange.com/questions/80815/what-is-a-product-id-in-usb-and-do-i-need-to-buy-it-for-my-project](https://electronics.stackexchange.com/questions/80815/what-is-a-product-id-in-usb-and-do-i-need-to-buy-it-for-my-project)
* [https://godoc.org/github.com/google/gousb](https://godoc.org/github.com/google/gousb)
* [https://github.com/faiface/beep](https://github.com/faiface/beep)
