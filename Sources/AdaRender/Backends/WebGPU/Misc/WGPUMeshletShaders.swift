#if WEBGPU_ENABLED && canImport(WebGPU) && !WASM
  enum WGPUMeshletShaders {
    static let source = """
      struct Cluster { range: vec4<u32>, minimum: vec4<f32>, maximum: vec4<f32>, reserved: vec4<u32> };
      struct View { projection: mat4x4<f32>, transform: mat4x4<f32>, config: vec4<u32>, lodProjection: mat4x4<f32>, lod: vec4<f32> };
      struct LODNode { minimum: vec4<f32>, maximum: vec4<f32>, metadata: vec4<u32> };
      @group(0) @binding(0) var<storage,read> clusters: array<Cluster>;
      @group(0) @binding(1) var<storage,read> source: array<u32>;
      @group(0) @binding(2) var<storage,read_write> counts: array<u32>;
      @group(0) @binding(3) var<storage,read_write> offsets: array<u32>;
      @group(0) @binding(4) var<storage,read_write> indices: array<u32>;
      @group(0) @binding(5) var<storage,read_write> arguments: array<u32>;
      @group(0) @binding(6) var<uniform> view: View;
      @group(0) @binding(7) var<storage,read_write> groupScratch: array<u32>;
      @group(0) @binding(8) var<storage,read> lodNodes: array<LODNode>;
      var<workgroup> prefix: array<u32,256>;

      fn visible(cluster: Cluster) -> bool {
          if (view.config.w != 0u) { return true; }
          // Match the CPU oracle: first expand the affine-transformed box to a world AABB.
          // Testing the tighter transformed OBB would produce different flags under rotation/shear.
          let localCenter=(cluster.minimum.xyz+cluster.maximum.xyz)*0.5;
          let e=(cluster.maximum.xyz-cluster.minimum.xyz)*0.5;
          let center=(view.transform*vec4<f32>(localCenter,1.0)).xyz;
          let extent=abs(view.transform[0].xyz)*e.x+abs(view.transform[1].xyz)*e.y+abs(view.transform[2].xyz)*e.z;
          if(any(center!=center) || any(abs(center)>vec3<f32>(3.402823e38))) { return true; }
          let rows=transpose(view.projection);
          let planes=array<vec4<f32>,6>(rows[3]+rows[0],rows[3]-rows[0],rows[3]+rows[1],rows[3]-rows[1],rows[2],rows[3]-rows[2]);
          for(var i=0u;i<6u;i=i+1u) {
              let plane=planes[i];
              let radius=abs(plane.x)*extent.x+abs(plane.y)*extent.y+abs(plane.z)*extent.z;
              if(dot(plane.xyz,center)+plane.w+radius < -0.0001) { return false; }
          }
          return true;
      }
      fn lodRadius(row: vec4<f32>, extent: vec3<f32>) -> f32 {
          return abs(row.x)*extent.x+abs(row.y)*extent.y+abs(row.z)*extent.z;
      }
      fn lodError(node: LODNode) -> f32 {
          let localCenter=(node.minimum.xyz+node.maximum.xyz)*0.5;
          let e=(node.maximum.xyz-node.minimum.xyz)*0.5;
          let center=(view.transform*vec4<f32>(localCenter,1.0)).xyz;
          let extent=abs(view.transform[0].xyz)*e.x+abs(view.transform[1].xyz)*e.y+abs(view.transform[2].xyz)*e.z;
          if(any(center!=center) || any(abs(center)>vec3<f32>(3.402823e38))) { return 3.402823e38; }
          let rows=transpose(view.lodProjection);
          let minimumW=dot(rows[3].xyz,center)+rows[3].w-lodRadius(rows[3],extent);
          let displacement=node.minimum.w*view.lod.w;
          let deltaW=displacement*length(rows[3].xyz);
          let expandedW=minimumW-deltaW;
          if(!(minimumW>0.0001) || !(expandedW>0.0001)) { return 3.402823e38; }
          let maximumX=abs(dot(rows[0].xyz,center)+rows[0].w)+lodRadius(rows[0],extent);
          let maximumY=abs(dot(rows[1].xyz,center)+rows[1].w)+lodRadius(rows[1],extent);
          let errorX=(displacement*length(rows[0].xyz)+maximumX/minimumW*deltaW)/expandedW*view.lod.x*0.5;
          let errorY=(displacement*length(rows[1].xyz)+maximumY/minimumW*deltaW)/expandedW*view.lod.y*0.5;
          return max(errorX,errorY);
      }
      fn lodSelected(cluster: Cluster) -> bool {
          if(view.lod.z<=0.0) { return true; }
          let own=lodNodes[cluster.reserved.x];
          if(own.metadata.y!=0u && !(lodError(own)<=view.lod.z)) { return false; }
          var parent=own.metadata.x;
          // Check all ancestors, so even a threshold-rounding tie cannot produce overlapping cuts.
          while(parent!=0xffffffffu) {
              let ancestor=lodNodes[parent];
              if(lodError(ancestor)<=view.lod.z) { return false; }
              parent=ancestor.metadata.x;
          }
          return true;
      }
      @compute @workgroup_size(256)
      fn classify(@builtin(global_invocation_id) id: vec3<u32>,
                  @builtin(local_invocation_index) lane: u32, @builtin(workgroup_id) group: vec3<u32>) {
          var count=0u;
          if(id.x < view.config.z) {
              let cluster=clusters[id.x];
              if(visible(cluster) && lodSelected(cluster)) { count=cluster.range.y; }
              counts[id.x]=count;
          }
          prefix[lane]=count;
          workgroupBarrier();
          for(var step=1u;step<256u;step=step*2u) {
              var preceding=0u;
              if(lane>=step) { preceding=prefix[lane-step]; }
              workgroupBarrier();
              prefix[lane]=prefix[lane]+preceding;
              workgroupBarrier();
          }
          if(id.x < view.config.z) { offsets[id.x]=prefix[lane]-count; }
          if(lane==255u) { groupScratch[group.x]=prefix[lane]; }
      }
      // Local prefixes are parallel; the final scan sees at most 256 workgroup totals.
      @compute @workgroup_size(1)
      fn scan() {
          var total=0u;
          let groups=(view.config.z+255u)/256u;
          for(var i=0u; i<groups; i=i+1u) {
              groupScratch[groups+i]=total;
              total=total+groupScratch[i];
          }
          let base=view.config.y*5u;
          arguments[base]=total;
          arguments[base+1u]=1u;
          arguments[base+2u]=view.config.x;
          arguments[base+3u]=0u;
          arguments[base+4u]=0u;
      }
      @compute @workgroup_size(64)
      fn scatter(@builtin(workgroup_id) group: vec3<u32>, @builtin(local_invocation_id) lane: vec3<u32>) {
          let id=group.x+1024u*group.y;
          if(id >= view.config.z) { return; }
          let cluster=clusters[id];
          let groups=(view.config.z+255u)/256u;
          let destination=view.config.x+groupScratch[groups+id/256u]+offsets[id];
          for(var i=lane.x; i<counts[id]; i=i+64u) {
              indices[destination+i]=source[cluster.range.x+i];
          }
      }
      """
  }
#endif
