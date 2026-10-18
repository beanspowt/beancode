import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import crypto from "node:crypto"

const STATE_ROOT = process.env.TEAM_BUS_DIR || path.join(os.homedir(), ".local", "share", "opencode-team")
const WAKE_DEFAULT = process.env.TEAM_BUS_WAKE !== "0"
const MAX_WAIT_S = 45
const MAX_CHAIN = 12
const TEAM_TIERS = new Set(["director", "manager", "lead", "worker", "auditor"])
const WAKE_TYPES = new Set(["task", "question", "answer", "blocker", "handoff", "result"])
const MSG_TYPES = ["task", "question", "answer", "status", "blocker", "handoff", "result", "broadcast"]
const TASK_STATUSES = ["open", "blocked", "done", "failed"]

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const renameRetry = async (from, to) => {
  for (let i = 0; ; i++) {
    try {
      await fs.rename(from, to)
      return
    } catch (e) {
      if (!["EPERM", "EBUSY", "EACCES"].includes(e.code) || i >= 25) throw e
      await sleep(15 + Math.random() * 40)
    }
  }
}

const safe = (s) => String(s).replace(/[^A-Za-z0-9._-]/g, "_")
const ok = (content) => ({ content })
const fail = (message) => ({ content: `ERROR: ${message}` })
const addr = (m) => `${m.agent}@${m.sessionID}`

function tierOf(agent) {
  if (agent === "director") return "director"
  if (agent === "auditor") return "auditor"
  if (typeof agent === "string" && agent.startsWith("manager-")) return "manager"
  if (typeof agent === "string" && agent.startsWith("lead-")) return "lead"
  if (typeof agent === "string" && agent.startsWith("worker-")) return "worker"
  return "other"
}

async function readJson(file) {
  try {
    return JSON.parse(await fs.readFile(file, "utf8"))
  } catch {
    return undefined
  }
}

async function writeJson(file, data) {
  await fs.mkdir(path.dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`
  await fs.writeFile(tmp, JSON.stringify(data, null, 2))
  try {
    await renameRetry(tmp, file)
  } catch (e) {
    await fs.rm(tmp, { force: true }).catch(() => {})
    throw e
  }
}

async function withLock(dir, fn) {
  const lock = path.join(dir, ".lock")
  await fs.mkdir(dir, { recursive: true })
  const start = Date.now()
  for (;;) {
    try {
      await fs.mkdir(lock)
      break
    } catch (e) {
      if (e.code !== "EEXIST") throw e
      try {
        const st = await fs.stat(lock)
        if (Date.now() - st.mtimeMs > 10_000) await fs.rm(lock, { recursive: true, force: true })
      } catch {}
      if (Date.now() - start > 15_000) throw new Error("team-bus: lock timeout")
      await sleep(25 + Math.random() * 50)
    }
  }
  try {
    return await fn()
  } finally {
    await fs.rm(lock, { recursive: true, force: true })
  }
}

const formatMsg = (m) =>
  `[TEAM MESSAGE ${m.id}] from ${m.from.agent}@${m.from.sessionID} (${m.from.tier}) | type=${m.type}` +
  `${m.taskId ? ` | task=${m.taskId}` : ""}${m.replyTo ? ` | reply_to=${m.replyTo}` : ""}\n` +
  `Subject: ${m.subject}\n\n${m.body}\n\n` +
  `(Reply with team_send to "${m.from.agent}@${m.from.sessionID}" if a response is needed.)`

export default {
  id: "team-bus",
  async setup(ctx) {
    const projectKey = safe(ctx.location?.project?.id ?? "global")
    const parentCache = new Map()
    const unwrap = (r) => (r && typeof r === "object" && r.data && typeof r.data === "object" ? r.data : r)

    const runDir = (runId) => path.join(STATE_ROOT, projectKey, safe(runId))
    const membersDir = (runId) => path.join(runDir(runId), "members")
    const inboxDir = (runId, sid) => path.join(runDir(runId), "inbox", safe(sid))
    const tasksDir = (runId) => path.join(runDir(runId), "tasks")

    async function sessionInfo(sessionID) {
      return unwrap(await ctx.session.get({ sessionID }))
    }

    async function parentOf(sessionID) {
      if (parentCache.has(sessionID)) return parentCache.get(sessionID)
      const info = await sessionInfo(sessionID)
      const parent = info?.parentID ?? null
      parentCache.set(sessionID, parent)
      return parent
    }

    async function lineage(sessionID) {
      const chain = [sessionID]
      let cur = sessionID
      for (let i = 0; i < MAX_CHAIN; i++) {
        const p = await parentOf(cur)
        if (!p) break
        chain.push(p)
        cur = p
      }
      return chain
    }

    async function identifyBy(sessionID, agent) {
      const chain = await lineage(sessionID)
      const runId = chain[chain.length - 1]
      const me = { sessionID, agent, tier: tierOf(agent), parentSessionID: chain[1] ?? null, runId, chain }
      const file = path.join(membersDir(runId), `${safe(sessionID)}.json`)
      const existing = await readJson(file)
      await writeJson(file, {
        created: existing?.created ?? Date.now(),
        sessionID,
        agent,
        tier: me.tier,
        parentSessionID: me.parentSessionID,
        runId,
        chain,
        lastSeen: Date.now(),
      })
      return me
    }

    async function identify(context) {
      const sessionID = context.sessionID
      let agent = context.agent
      if (!agent) agent = (await sessionInfo(sessionID))?.agent ?? "unknown"
      return identifyBy(sessionID, agent)
    }

    async function members(runId) {
      let names = []
      try {
        names = await fs.readdir(membersDir(runId))
      } catch {}
      const out = []
      for (const n of names) {
        if (!n.endsWith(".json")) continue
        const m = await readJson(path.join(membersDir(runId), n))
        if (m) out.push(m)
      }
      return out
    }

    function resolveTargets(me, to, all) {
      const others = all.filter((m) => m.sessionID !== me.sessionID)
      if (to === "@team") return others
      if (to === "@parent") return others.filter((m) => m.sessionID === me.parentSessionID)
      if (to === "@siblings") return others.filter((m) => m.parentSessionID && m.parentSessionID === me.parentSessionID)
      if (to === "@subtree") return others.filter((m) => (m.chain ?? []).includes(me.sessionID))
      if (to.startsWith("@tier:")) return others.filter((m) => m.tier === to.slice(6))
      const at = to.indexOf("@")
      const id = at > 0 ? to.slice(at + 1) : to
      const bySession = others.filter((m) => m.sessionID === id)
      if (bySession.length) return bySession
      return others.filter((m) => m.agent === to)
    }

    function relation(me, t) {
      const tc = t.chain ?? [t.sessionID]
      if (tc.includes(me.sessionID)) return "down"
      if (me.chain[1] === t.sessionID) return "up-direct"
      if (me.chain.includes(t.sessionID)) return "up-skip"
      if (me.chain[1] && tc[1] === me.chain[1]) return "sibling"
      return "cross"
    }

    function denyReason(me, rel) {
      if (me.tier === "other") return null
      if (rel === "down" || rel === "up-direct" || rel === "sibling") return null
      if (rel === "up-skip") return me.tier === "worker" ? "workers may only message their direct supervisor (use to:\"@parent\")" : null
      return "cross-team message blocked; send it to your supervisor (to:\"@parent\") and ask them to route it"
    }

    async function deliver({ run, from, target, type, subject, body, replyTo, taskId, wake }) {
      const id = `${String(Date.now()).padStart(13, "0")}-${crypto.randomBytes(3).toString("hex")}`
      const msg = {
        id,
        type,
        subject: subject ?? "",
        body,
        replyTo: replyTo ?? null,
        taskId: taskId ?? null,
        from: { agent: from.agent, sessionID: from.sessionID, tier: from.tier },
        to: { agent: target.agent, sessionID: target.sessionID },
        time: Date.now(),
      }
      await writeJson(path.join(runDir(run), "log", `${id}.json`), msg)
      let woke = false
      if (wake) {
        try {
          await ctx.session.prompt({ sessionID: target.sessionID, text: formatMsg(msg), delivery: "steer" })
          woke = true
        } catch (e) {
          console.warn(`[team-bus] live delivery to ${target.sessionID} failed: ${e?.message ?? e}`)
        }
      }
      const dest = woke ? path.join(inboxDir(run, target.sessionID), "read") : inboxDir(run, target.sessionID)
      await writeJson(path.join(dest, `${id}.json`), msg)
      return { id, woke }
    }

    async function unreadNames(run, sid) {
      let names = []
      try {
        names = await fs.readdir(inboxDir(run, sid))
      } catch {}
      return names.filter((n) => n.endsWith(".json")).sort()
    }

    async function consume(me, limit, peek) {
      const names = (await unreadNames(me.runId, me.sessionID)).slice(0, limit)
      if (!names.length) return ok("Inbox empty.")
      const dir = inboxDir(me.runId, me.sessionID)
      if (!peek) await fs.mkdir(path.join(dir, "read"), { recursive: true })
      const parts = []
      for (const n of names) {
        const msg = await readJson(path.join(dir, n))
        if (!msg) continue
        parts.push(formatMsg(msg))
        if (!peek) await renameRetry(path.join(dir, n), path.join(dir, "read", n))
      }
      return ok(parts.join("\n\n-----\n\n") || "Inbox empty.")
    }

    const taskLine = (t) =>
      `${t.id} | ${t.status} | assignee=${t.assignee ?? "-"} | owner=${t.owner ? addr(t.owner) : "-"} | ${t.title}` +
      `${t.scope?.length ? ` | scope=${t.scope.join(",")}` : ""}${t.depends_on?.length ? ` | deps=${t.depends_on.join(",")}` : ""}`

    async function readTasks(run) {
      let names = []
      try {
        names = await fs.readdir(tasksDir(run))
      } catch {}
      const out = []
      for (const n of names.filter((x) => /^T\d+\.json$/.test(x))) {
        const t = await readJson(path.join(tasksDir(run), n))
        if (t) out.push(t)
      }
      return out.sort((a, b) => Number(a.id.slice(1)) - Number(b.id.slice(1)))
    }

    const def = (name, description, properties, required, run) => ({
      name,
      description,
      input: { type: "object", properties, required, additionalProperties: false },
      options: { codemode: false },
      execute: async (input, context) => {
        try {
          return await run(input ?? {}, context)
        } catch (e) {
          return fail(e?.message ?? String(e))
        }
      },
    })

    const TOOLS = [
      def("team_whoami", "Show your team address, tier, supervisor and run id. Call this first in every session.", {}, [], async (_i, context) => {
        const me = await identify(context)
        return ok(
          JSON.stringify(
            { address: addr(me), agent: me.agent, tier: me.tier, sessionID: me.sessionID, supervisor: me.parentSessionID, runId: me.runId, stateDir: runDir(me.runId) },
            null,
            2,
          ),
        )
      }),

      def("team_roster", "List all team members seen in this run (agent, tier, session id, supervisor, last activity).", {}, [], async (_i, context) => {
        const me = await identify(context)
        const all = (await members(me.runId)).sort((a, b) => a.created - b.created)
        const now = Date.now()
        const lines = all.map(
          (m) => `${addr(m)} | tier=${m.tier} | supervisor=${m.parentSessionID ?? "-"} | seen ${Math.round((now - m.lastSeen) / 1000)}s ago${m.sessionID === me.sessionID ? " | (you)" : ""}`,
        )
        return ok(lines.join("\n") || "No members yet.")
      }),

      def(
        "team_send",
        'Send a message to a teammate. "to" = "agent@sessionID", a session id, an agent id (all live instances), or @parent, @siblings, @subtree, @team, @tier:<tier>. Org rules are enforced.',
        {
          to: { type: "string" },
          type: { type: "string", enum: MSG_TYPES },
          subject: { type: "string" },
          body: { type: "string" },
          reply_to: { type: "string" },
          task_id: { type: "string" },
          wake: { type: "boolean", description: "Push into the recipient's session immediately. Default: true except for status/broadcast." },
        },
        ["to", "type", "body"],
        async (input, context) => {
          const me = await identify(context)
          if (!MSG_TYPES.includes(input.type)) return fail(`type must be one of ${MSG_TYPES.join(", ")}`)
          if (!input.body || !String(input.body).trim()) return fail("body is required")
          const all = await members(me.runId)
          const targets = resolveTargets(me, String(input.to), all)
          if (!targets.length) return fail(`no live member matches "${input.to}". Call team_roster; the target may not have started yet.`)
          const sent = []
          const blocked = []
          for (const t of targets) {
            const reason = denyReason(me, relation(me, t))
            if (reason) {
              blocked.push(`${addr(t)}: ${reason}`)
              continue
            }
            const wake = input.wake ?? (WAKE_DEFAULT && WAKE_TYPES.has(input.type))
            const r = await deliver({ run: me.runId, from: me, target: t, type: input.type, subject: input.subject, body: String(input.body), replyTo: input.reply_to, taskId: input.task_id, wake })
            sent.push(`${addr(t)} (id ${r.id}, ${r.woke ? "delivered live" : "queued in inbox"})`)
          }
          if (!sent.length) return fail(`not delivered. ${blocked.join("; ")}`)
          return ok(`Sent to: ${sent.join("; ")}${blocked.length ? `\nBlocked: ${blocked.join("; ")}` : ""}`)
        },
      ),

      def(
        "team_inbox",
        "Read your unread team messages (marks them read unless peek=true).",
        { limit: { type: "number" }, peek: { type: "boolean" } },
        [],
        async (input, context) => {
          const me = await identify(context)
          return consume(me, Math.max(1, Math.min(Number(input.limit ?? 20), 50)), input.peek === true)
        },
      ),

      def(
        "team_log",
        "Director-only, read-only: view every message exchanged on the team bus in this run (all senders/recipients), without marking anything read. Filters: limit (default 30, max 100, newest last), after (message id), type, agent (matches sender or recipient), task_id.",
        {
          limit: { type: "number" },
          after: { type: "string", description: "Only messages with id greater than this." },
          type: { type: "string", enum: MSG_TYPES },
          agent: { type: "string", description: "Agent id or session id; matches sender or recipient." },
          task_id: { type: "string" },
        },
        [],
        async (input, context) => {
          const me = await identify(context)
          if (me.tier !== "director") return fail("team_log is available to the director only")
          let names = []
          try {
            names = await fs.readdir(path.join(runDir(me.runId), "log"))
          } catch {}
          names = names.filter((n) => n.endsWith(".json")).sort()
          if (input.after) names = names.filter((n) => n.slice(0, -5) > input.after)
          const msgs = []
          for (const n of names) {
            const m = await readJson(path.join(runDir(me.runId), "log", n))
            if (!m) continue
            if (input.type && m.type !== input.type) continue
            if (input.task_id && m.taskId !== input.task_id) continue
            if (input.agent && ![m.from?.agent, m.from?.sessionID, m.to?.agent, m.to?.sessionID].includes(input.agent)) continue
            msgs.push(m)
          }
          const limit = Math.max(1, Math.min(Number(input.limit ?? 30), 100))
          const shown = msgs.slice(-limit)
          const lines = shown.map(
            (m) =>
              `[${m.id}] ${new Date(m.time).toISOString()} ${m.from.agent}@${m.from.sessionID} -> ${m.to.agent}@${m.to.sessionID} | type=${m.type}` +
              `${m.taskId ? ` | task=${m.taskId}` : ""}${m.replyTo ? ` | reply_to=${m.replyTo}` : ""}\nSubject: ${m.subject}\n${m.body}`,
          )
          const head = `${shown.length} of ${msgs.length} message(s)${msgs.length > shown.length ? " (older omitted; use after/limit)" : ""}`
          return ok(shown.length ? `${head}\n\n${lines.join("\n\n-----\n\n")}` : "No messages logged.")
        },
      ),

      def(
        "team_wait",
        "Block until a team message arrives or timeout_s (1-45) elapses. Use only when blocked on a specific reply; never in a tight loop.",
        { timeout_s: { type: "number" } },
        [],
        async (input, context) => {
          const me = await identify(context)
          const timeout = Math.min(Math.max(Number(input.timeout_s ?? 30), 1), MAX_WAIT_S) * 1000
          const end = Date.now() + timeout
          while (Date.now() < end) {
            if (context.signal?.aborted) return ok("Wait cancelled.")
            if ((await unreadNames(me.runId, me.sessionID)).length) return consume(me, 20, false)
            await sleep(750)
          }
          return ok("No new messages (timeout).")
        },
      ),

      def(
        "team_task_create",
        "Create a task on the shared board. Directors, managers and leads only. assignee = agent id (pool) or agent@sessionID.",
        {
          title: { type: "string" },
          description: { type: "string" },
          assignee: { type: "string" },
          scope: { type: "array", items: { type: "string" }, description: "File/dir globs the task may touch." },
          depends_on: { type: "array", items: { type: "string" } },
        },
        ["title"],
        async (input, context) => {
          const me = await identify(context)
          if (me.tier === "worker" || me.tier === "auditor") return fail("workers and auditors cannot create tasks")
          const dir = tasksDir(me.runId)
          const task = await withLock(dir, async () => {
            const seqFile = path.join(dir, ".seq")
            const n = ((await readJson(seqFile))?.n ?? 0) + 1
            await writeJson(seqFile, { n })
            const t = {
              id: `T${n}`,
              title: String(input.title),
              description: input.description ?? "",
              creator: { agent: me.agent, sessionID: me.sessionID },
              assignee: input.assignee ?? null,
              scope: input.scope ?? [],
              depends_on: input.depends_on ?? [],
              status: "open",
              owner: null,
              result: null,
              notes: [],
              created: Date.now(),
              updated: Date.now(),
            }
            await writeJson(path.join(dir, `${t.id}.json`), t)
            return t
          })
          return ok(`Created ${taskLine(task)}`)
        },
      ),

      def(
        "team_task_list",
        "List tasks on the board. Filters: status, mine (owned by or assigned to you).",
        { status: { type: "string", enum: TASK_STATUSES.concat(["claimed"]) }, mine: { type: "boolean" } },
        [],
        async (input, context) => {
          const me = await identify(context)
          let tasks = await readTasks(me.runId)
          if (input.status) tasks = tasks.filter((t) => t.status === input.status)
          if (input.mine) tasks = tasks.filter((t) => t.owner?.sessionID === me.sessionID || t.assignee === me.agent || t.assignee === addr(me) || t.assignee === me.sessionID)
          return ok(tasks.map(taskLine).join("\n") || "No tasks.")
        },
      ),

      def("team_task_claim", "Claim an open task assigned to you or to your agent id (or unassigned). Fails if dependencies are not done.", { id: { type: "string" } }, ["id"], async (input, context) => {
        const me = await identify(context)
        const dir = tasksDir(me.runId)
        return withLock(dir, async () => {
          const file = path.join(dir, `${safe(input.id)}.json`)
          const t = await readJson(file)
          if (!t) return fail(`task ${input.id} not found`)
          if (t.status !== "open") return fail(`task ${t.id} is ${t.status}`)
          if (t.assignee && t.assignee !== me.agent && t.assignee !== me.sessionID && t.assignee !== addr(me)) return fail(`task ${t.id} is assigned to ${t.assignee}`)
          for (const dep of t.depends_on ?? []) {
            const d = await readJson(path.join(dir, `${safe(dep)}.json`))
            if (!d || d.status !== "done") return fail(`dependency ${dep} is not done`)
          }
          t.status = "claimed"
          t.owner = { agent: me.agent, sessionID: me.sessionID }
          t.updated = Date.now()
          await writeJson(file, t)
          return ok(`Claimed ${taskLine(t)}`)
        })
      }),

      def(
        "team_task_update",
        "Update a task you own (or any task if you are a director/manager/lead). done/failed notify the task creator.",
        { id: { type: "string" }, status: { type: "string", enum: TASK_STATUSES }, result: { type: "string" }, note: { type: "string" } },
        ["id", "status"],
        async (input, context) => {
          const me = await identify(context)
          const dir = tasksDir(me.runId)
          const t = await withLock(dir, async () => {
            const file = path.join(dir, `${safe(input.id)}.json`)
            const cur = await readJson(file)
            if (!cur) return { error: `task ${input.id} not found` }
            const privileged = ["director", "manager", "lead", "other"].includes(me.tier)
            if (!privileged && cur.owner?.sessionID !== me.sessionID) return { error: "only the task owner can update this task" }
            cur.status = input.status
            if (input.status === "open") cur.owner = null
            if (input.result) cur.result = input.result
            if (input.note) cur.notes.push({ by: addr(me), at: Date.now(), text: input.note })
            cur.updated = Date.now()
            await writeJson(file, cur)
            return { task: cur }
          })
          if (t.error) return fail(t.error)
          const task = t.task
          if ((task.status === "done" || task.status === "failed") && task.creator?.sessionID && task.creator.sessionID !== me.sessionID) {
            await deliver({
              run: me.runId,
              from: me,
              target: task.creator,
              type: "result",
              subject: `${task.id} ${task.status}: ${task.title}`,
              body: task.result ?? "(no summary)",
              taskId: task.id,
              wake: WAKE_DEFAULT,
            })
          }
          return ok(`Updated ${taskLine(task)}`)
        },
      ),
    ]

    await ctx.tool.transform((editor) => {
      for (const t of TOOLS) editor.add(t)
    })

    await ctx.session.hook("context", async (event) => {
      try {
        if (!TEAM_TIERS.has(tierOf(event.agent))) return
        const me = await identifyBy(event.sessionID, event.agent)
        const n = (await unreadNames(me.runId, me.sessionID)).length
        if (n > 0) event.system.push({ type: "text", text: `[TEAM] You have ${n} unread team message(s). Call team_inbox before continuing.` })
      } catch (e) {
        console.warn(`[team-bus] context hook: ${e?.message ?? e}`)
      }
    })
  },
}
