const KEY='bloxflow.review.filters.v1';
const queues=new Set(['needs_review','approved','rejected','later']);
export function normalizeReviewFilters(value={}){return {sector:typeof value?.sector==='string'?value.sector:null,subsector:typeof value?.subsector==='string'?value.subsector:'all',queue:queues.has(value?.queue)?value.queue:'needs_review',withWebsite:value?.withWebsite!==false};}
export function loadReviewFilters(storage){try{return normalizeReviewFilters(JSON.parse(storage.getItem(KEY)||'{}'))}catch{return normalizeReviewFilters()}}
export function saveReviewFilters(storage,value){const clean=normalizeReviewFilters(value);try{storage.setItem(KEY,JSON.stringify(clean))}catch{}return clean;}
