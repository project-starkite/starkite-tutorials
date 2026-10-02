def main():
    client = containers.config()

    # Ping returns True if daemon responds
    if not client.ping():
        fail("Container daemon is unreachable")

    # Inspect endpoint properties
    print("Endpoint:", client.endpoint)
    print("Socket Path:", client.socket)

    # Retrieve version information dictionary
    v = client.version()
    print("Engine Version:", v["Version"])
    print("API Version:", v["ApiVersion"])
    print("Operating System:", v["Os"])
    print("Architecture:", v["Arch"])