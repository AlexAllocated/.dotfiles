# syntax=docker/dockerfile:1
#
# Canonical build:
#   nix build .#docker-pocket-knife
#   docker load < result
#
# This Dockerfile is intentionally thin so downstream machines can extend the
# published image without duplicating the Nix image definition.

ARG BASE_IMAGE=ghcr.io/alexallocated/dotfiles-pocket-knife:latest
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/AlexAllocated/.dotfiles"
