---
title: "Creating your homelab using Raspberry Pis and K3s for fun and no profit"
date: 2020-11-30T02:23:45Z
tags: homelab raspberry-pi k3s golang
---

# Introduction

For the last few months, I've been building my homelab. It has now become a pretty huge project and I thought that doing
a writeup on how it all works at the moment would somehow justify its existence. You can view the repository for it
[here](https://github.com/davidsbond/homelab). It's a monorepo, so everything that my homelab consists of lives in there. 

Each section of this post is going to explain a different aspect of the system.

# Hardware

This section discusses all the hardware that goes into my homelab. The hardware list is as follows:

* 4x Raspberry Pi 4b (8GB RAM)
* 1x Zebra Bramble Cluster Case from C4 Labs
* 4x SanDisk Ultra 32 GB microSDHC Memory Cards
* 4x SanDisk Ultra Fit 128 GB USB 3.1 Flash Drive USB Drives
* 1x Synology DS115j NAS drive.

Each node in the cluster is running on a Raspberry Pi 4b, the 8GB model. These things surprised me with how powerful they
are. With the dumb amount of things I have running, I normally see node CPU usage around 30-40 percent and memory usage at
most around 40 percent.

![Nodes](/images/2020-11-30-homelab/1.png)

The Pis each have 32GB of storage for the OS. This wasn't entirely suitable for all the things I had in mind. I'd also read
that these SD cards can die on you pretty quick in some scenarios. So I expanded that storage with a 128GB USB3.1 stick 
in each one. This was ultimately what ended up being used for my volume storage. The read/write speeds were what I
expected of a 3.1 port, no complaints. Some of the reviews on Amazon suggested the USB sticks get quite hot, although
I haven't experienced this myself.

The case is one produced by C4 Labs and is designed to house 4 Pis, each with a fan and heatsinks. It was a little tricky
to put together but looked great once it was all there.

![Case](/images/2020-11-30-homelab/2.jpg)

Initially, these things didn't run too hot. Once I got my full workload going on there, they started running around
40/45 degrees while idling. In this 12 hour graph, you can see things spike when I was uploading images to my
Google Photos replacement.

![Temperature](/images/2020-11-30-homelab/3.png)

# Infrastructure

Each node is using [Ubuntu for Raspberry Pi](https://ubuntu.com/raspberry-pi) as its operating system. It is literally 
just Ubuntu Server running on each Pi. The description below is from the Ubuntu website:

> A tiny machine with a giant impact. The Ubuntu community and Canonical are proud to enable desktop, server and 
> production internet of things on the Raspberry Pi. In support of inventors, educators, entrepreneurs and eccentrics 
> everywhere, we join the Raspberry Pi Foundation in striving to deliver the most open platform at the lowest price, 
> powered by our communities.

So far, it works exactly as you would expect Ubuntu to work. I haven't had a single issue with the OS. The most
frequent problem I've had is support for arm64 for applications. A few of the apps I'm running use some random
person's docker image that does an arm64 build while I wait for the actual maintainers to add the support. It feels
as though we're probably a year or two away from arm64 being treated as a first-class citizen the same way amd64 is.

That being said, support for said support is pretty popular, and almost all the things I wanted to run that didn't
already have arm64 support had issues on their repositories requesting it.

## Container Orchestration

## Infrastructure as code

## Cluster upgrades

# Tooling

* Golang
* Kustomize
* Docker Buildx
* Terraform
* K9s

# Observability

## Tracing

## Metrics

## Presentation

# Storage

## Volumes

## Blob storage

## Databases

## Backups

# Networking

## VPN

## Ingress

## DNS

## TLS

# Applications

In this section, I'll explain the different applications I'm running. Here's a diagram with a visual representation:

![Diagram](/images/2020-11-30-homelab/4.jpg)

## Bytecrypt

## Firefly

## Photoprism

## Home Assistant
