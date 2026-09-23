---
title: Infra Review
date: 2026-05-07
granola_url: "https://notes.granola.example/d/3331f212c3a5a0ab5e641ebb0d4fcb49"
granola_id: not_3331f212c3a5a0ab
source: granola
case: neg-terminate-instance
expect_categories: []
expect_min_redactions: 0
---

# 2026-05-07 Infra Review

- Terminate the stuck instance before redeploying; the process termination hook needs a timeout.
- We reassign the shard once the node terminates cleanly.
