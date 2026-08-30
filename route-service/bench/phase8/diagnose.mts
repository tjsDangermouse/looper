/** Which cheap pre-route features predict each rejection and each leg's inflation. */
import { readFileSync } from 'node:fs'
import { ancestry, loadFields, median } from './field.mjs'

const fields = loadFields(new URL('network-fields.json', import.meta.url))
const offline = JSON.parse(readFileSync(new URL(`results/offline-${process.env.LABEL ?? 'best'}.json`, import.meta.url), 'utf8'))
for (const field of fields) {
  const rows = offline.results.filter((row: any) => row.fixture === field.name)
  const byId = new Map(field.nodes.map(node => [node.node, node]))
  const table = rows.map((row: any) => {
    const [a, , c] = row.anchors.map((id: number) => byId.get(id)!)
    const tie = ancestry(field, a, c)
    return {
      rejections: row.rejections as string[],
      shared: tie.sharedMetres, sharedFraction: tie.sharedFraction,
      leg3: row.legDistances[3] / Math.max(1, c.networkMetres),
      ratio: row.distance / row.predicted,
    }
  })
  const split = (name: string, filter: (row: any) => boolean) => {
    const yes = table.filter(filter), no = table.filter((row: any) => !filter(row))
    if (!yes.length || !no.length) return
    console.log(`  ${name.padEnd(20)} n=${String(yes.length).padStart(2)}  A/C shared corridor ${median(yes.map((r: any) => r.shared)).toFixed(0)} m vs ${median(no.map((r: any) => r.shared)).toFixed(0)} m`)
  }
  console.log(field.name)
  split('out-and-back-spur', (row: any) => row.rejections.includes('out-and-back-spur'))
  split('shapeless', (row: any) => row.rejections.includes('shapeless'))
  split('PASS', (row: any) => !row.rejections.length)
  const high = table.filter((r: any) => r.shared > 150), low = table.filter((r: any) => r.shared <= 150)
  console.log(`  closing leg routed/field: A/C shares >150 m ${median(high.map((r: any) => r.leg3)).toFixed(3)} (n=${high.length}) vs <=150 m ${median(low.map((r: any) => r.leg3)).toFixed(3)} (n=${low.length})`)
  console.log(`  candidate actual/predicted: ${median(high.map((r: any) => r.ratio)).toFixed(3)} vs ${median(low.map((r: any) => r.ratio)).toFixed(3)}`)
  console.log()
}
