import type { CSSProperties, ReactNode } from 'react'
export const characters = [
  { id:'sun', icon:'☀️', label:'Sol' }, { id:'wind', icon:'🌬️', label:'Vento' }, { id:'leaf', icon:'🌿', label:'Folha' }, { id:'battery', icon:'🔋', label:'Bateria' },
  { id:'drop', icon:'💧', label:'Água' }, { id:'solar', icon:'🌞', label:'Solar' }, { id:'bulb', icon:'💡', label:'Luz' }, { id:'earth', icon:'🌎', label:'Terra' },
  { id:'recycle', icon:'♻️', label:'Circular' }, { id:'bike', icon:'🚲', label:'Mobilidade' }, { id:'plug', icon:'🔌', label:'Energia' }, { id:'sprout', icon:'🪴', label:'Broto' },
]
export function Avatar({ character, color='#b9f93c', size='md' }: { character:string; color?:string; size?:'sm'|'md'|'lg' }) {
  const found=characters.find(c=>c.id===character)??characters[0]
  return <span className={`avatar avatar-${size}`} style={{'--avatar-color':color} as CSSProperties} role="img" aria-label={found.label}>{found.icon}</span>
}
export function EnergyMark(): ReactNode { return <span className="energy-mark" aria-hidden="true"><span>ϟ</span></span> }
