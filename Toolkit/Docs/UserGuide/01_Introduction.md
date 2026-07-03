# Introduction

## What Core Diagnostic Engine does

Core Diagnostic Engine (CDE) is a repair and diagnostics toolkit for Windows PCs. It helps you find problems (slow performance, malware, boot failures, update errors) and run trusted repair steps from one organized program.

CDE can run in two main environments:

| Environment | When you use it | What it means |
|-------------|-----------------|---------------|
| **WinPE Mode** | Boot from the CDE USB stick | A minimal Windows recovery environment. Best when Windows will not start normally or you need offline access to the customer's drive. |
| **Windows Mode** | Run `CDE.exe` on a working Windows install | Full access to live Windows services, Windows Update, and most repair tools while Windows is running. |

## What is on the USB toolkit

The CDE USB drive typically includes:

- **CDE WinPE** — boots into the graphical CDE program
- **Core Hardware Utility (CHU)** — pre-boot hardware tests before Windows loads
- **Windows Memory Diagnostic** — memory test tool (when staged on the USB)

## How this guide is organized

Each chapter explains **what a tool does**, **when to use it**, and **step-by-step instructions**. Callout boxes highlight tips, warnings, and WinPE-only features.

Start with **Getting Started** if you are new to CDE, then follow the **Recommended Repair Workflow** for a practical order of operations on a typical service bench job.
