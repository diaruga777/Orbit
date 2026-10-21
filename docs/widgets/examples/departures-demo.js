/* orbit-widget
{"id":"departures-demo","name":"Train Departures Demo","domains":[],"refreshMinutes":30}
*/
// Offline example. Replace update with a documented transit API for live data.
module.exports = {
  update(ctx) {
    ctx.storage.set('departures', [5, 13, 26].map(minutes => ({
      destination: 'Central', date: new Date(ctx.now.getTime() + minutes * 60000).toISOString()
    })));
  },
  render(ctx) { return view(ctx, ctx.now); },
  timeline(ctx) {
    return ctx.storage.get('departures', []).map(train => ({
      date: train.date, view: view(ctx, new Date(train.date))
    }));
  }
};
function view(ctx, now) {
  const next = ctx.storage.get('departures', []).find(train => new Date(train.date) > now);
  if (ctx.family === 'inline') return {type:'text',text:next ? 'Demo · '+next.destination : 'No more trains'};
  if (ctx.family === 'circular') return {type:'symbol',symbol:'tram.fill'};
  return {type:'vstack',spacing:8,children:[
    {type:'hstack',children:[{type:'symbol',symbol:'tram.fill',color:'accent'}, {type:'text',text:'Sample departures',size:12,color:'secondary'}]},
    {type:'text',text:next ? next.destination : 'No more trains',size:22,weight:'bold'},
    next ? {type:'date',date:next.date,size:18} : {type:'text',text:'Open Orbit to refresh',size:12}
  ]};
}
