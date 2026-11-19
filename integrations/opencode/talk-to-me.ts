// Talk to Me for OpenCode: speaks the assistant's reply when a session goes
// idle (the turn is done). Installed by `talktome install opencode` into
// ~/.config/opencode/plugins/, which replaces __TALKTOME__ with the CLI path.
//
// Sub-agent sessions (they have a parentID) are skipped so only the reply you
// see is read.

const TALKTOME = "__TALKTOME__"

export const TalkToMe = async ({ client, directory }: any) => {
  return {
    event: async ({ event }: any) => {
      if (event?.type !== "session.idle") return
      const id: string | undefined = event.properties?.sessionID
      if (!id) return
      try {
        const session = await client.session.get({ path: { id } })
        if (session?.data?.parentID) return

        const res = await client.session.messages({ path: { id } })
        const messages: any[] = res?.data ?? []
        const last = [...messages].reverse().find((m) => m.info?.role === "assistant")
        if (!last) return
        const text = (last.parts ?? [])
          .filter((p: any) => p.type === "text" && !p.synthetic && !p.ignored)
          .map((p: any) => p.text)
          .join("\n\n")
          .trim()
        if (!text) return

        const payload = JSON.stringify({ session_id: id, cwd: directory, text })
        const proc = Bun.spawn([TALKTOME, "hook", "opencode"], {
          stdin: new Blob([payload]),
          stdout: "ignore",
          stderr: "ignore",
        })
        proc.unref()
      } catch {
        // never disturb the session
      }
    },
  }
}
