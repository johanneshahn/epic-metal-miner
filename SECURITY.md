# Security and privacy

Do not commit wallet files, Epicbox addresses, node or pool credentials, API
secrets, runtime logs, `.build` output, or local node configuration.

The miner sends its configured worker identity and password to the selected
Stratum endpoint. Use only endpoints you trust. Pool connections are plain TCP
when required by the pool; this project does not silently add TLS.

Report security-sensitive issues privately to the repository owner rather than
including credentials or wallet data in a public issue.
