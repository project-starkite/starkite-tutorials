def main():
    client = containers.config()
    c = client.run("alpine:latest", command=["sleep", "300"], detach=True)
    defer(lambda: c.remove(force=True))

    # Run command inside container
    res = c.exec(["echo", "Hello from Starkite"])
    print("Exit code:", res.exit_code)
    print("Stdout:", res.stdout.strip())
    print("Success:", res.ok)