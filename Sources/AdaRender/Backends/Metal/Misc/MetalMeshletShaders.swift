#if METAL
  enum MetalMeshletShaders {
    static let source = """
      #include <metal_stdlib>
      using namespace metal;
      struct Cluster { uint4 range; float4 minimum; float4 maximum; uint4 reserved; };
      struct View { float4x4 projection; float4x4 transform; uint4 config; float4x4 lodProjection; float4 lod; };
      struct LODNode { float4 minimum; float4 maximum; uint4 metadata; };
      bool visible(Cluster cluster, constant View& view) {
          if(view.config.w!=0) return true;
          float3 localCenter=(cluster.minimum.xyz+cluster.maximum.xyz)*0.5;
          float3 e=(cluster.maximum.xyz-cluster.minimum.xyz)*0.5;
          float3 center=(view.transform*float4(localCenter,1)).xyz;
          float3 extent=abs(view.transform[0].xyz)*e.x+abs(view.transform[1].xyz)*e.y+abs(view.transform[2].xyz)*e.z;
          if(any(isnan(center)) || any(isinf(center))) return true;
          float4x4 rows=transpose(view.projection);
          float4 planes[6]={rows[3]+rows[0],rows[3]-rows[0],rows[3]+rows[1],rows[3]-rows[1],rows[2],rows[3]-rows[2]};
          for(uint i=0;i<6;++i) {
              float4 plane=planes[i];
              float radius=abs(plane.x)*extent.x+abs(plane.y)*extent.y+abs(plane.z)*extent.z;
              if(dot(plane.xyz,center)+plane.w+radius < -0.0001) return false;
          }
          return true;
      }
      float lodRadius(float4 row,float3 extent) {
          return abs(row.x)*extent.x+abs(row.y)*extent.y+abs(row.z)*extent.z;
      }
      float lodError(LODNode node,constant View& view) {
          float3 localCenter=(node.minimum.xyz+node.maximum.xyz)*0.5;
          float3 e=(node.maximum.xyz-node.minimum.xyz)*0.5;
          float3 center=(view.transform*float4(localCenter,1)).xyz;
          float3 extent=abs(view.transform[0].xyz)*e.x+abs(view.transform[1].xyz)*e.y+abs(view.transform[2].xyz)*e.z;
          if(any(isnan(center)) || any(isinf(center))) return 3.402823e38f;
          float4x4 rows=transpose(view.lodProjection);
          float minimumW=dot(rows[3].xyz,center)+rows[3].w-lodRadius(rows[3],extent);
          float displacement=node.minimum.w*view.lod.w;
          float deltaW=displacement*length(rows[3].xyz);
          float expandedW=minimumW-deltaW;
          if(!(minimumW>0.0001) || !(expandedW>0.0001)) return 3.402823e38f;
          float maximumX=abs(dot(rows[0].xyz,center)+rows[0].w)+lodRadius(rows[0],extent);
          float maximumY=abs(dot(rows[1].xyz,center)+rows[1].w)+lodRadius(rows[1],extent);
          float errorX=(displacement*length(rows[0].xyz)+maximumX/minimumW*deltaW)/expandedW*view.lod.x*0.5;
          float errorY=(displacement*length(rows[1].xyz)+maximumY/minimumW*deltaW)/expandedW*view.lod.y*0.5;
          return max(errorX,errorY);
      }
      bool lodSelected(Cluster cluster,device const LODNode* nodes,constant View& view) {
          if(view.lod.z<=0) return true;
          LODNode own=nodes[cluster.reserved.x];
          if(own.metadata.y!=0 && !(lodError(own,view)<=view.lod.z)) return false;
          uint parent=own.metadata.x;
          while(parent!=0xffffffffu) {
              LODNode ancestor=nodes[parent];
              if(lodError(ancestor,view)<=view.lod.z) return false;
              parent=ancestor.metadata.x;
          }
          return true;
      }
      kernel void meshlet_classify(device const Cluster* clusters [[buffer(0)]],device const uint* source [[buffer(1)]],
          device uint* counts [[buffer(2)]],device uint* offsets [[buffer(3)]],device uint* indices [[buffer(4)]],
          device uint* arguments [[buffer(5)]],constant View& view [[buffer(6)]],device uint* groupScratch [[buffer(7)]],device const LODNode* nodes [[buffer(8)]],
          uint id [[thread_position_in_grid]],uint lane [[thread_index_in_threadgroup]],uint3 group [[threadgroup_position_in_grid]]) {
          threadgroup uint prefix[256];
          uint count=0;
          if(id<view.config.z) { count=visible(clusters[id],view)&&lodSelected(clusters[id],nodes,view)?clusters[id].range.y:0; counts[id]=count; }
          prefix[lane]=count;
          threadgroup_barrier(mem_flags::mem_threadgroup);
          for(uint step=1;step<256;step*=2) {
              uint preceding=0;
              if(lane>=step) preceding=prefix[lane-step];
              threadgroup_barrier(mem_flags::mem_threadgroup);
              prefix[lane]+=preceding;
              threadgroup_barrier(mem_flags::mem_threadgroup);
          }
          if(id<view.config.z) offsets[id]=prefix[lane]-count;
          if(lane==255) groupScratch[group.x]=prefix[lane];
      }
      kernel void meshlet_scan(device const Cluster* clusters [[buffer(0)]],device const uint* source [[buffer(1)]],
          device uint* counts [[buffer(2)]],device uint* offsets [[buffer(3)]],device uint* indices [[buffer(4)]],
          device uint* arguments [[buffer(5)]],constant View& view [[buffer(6)]],device uint* groupScratch [[buffer(7)]],uint id [[thread_position_in_grid]]) {
          if(id!=0) return;
          uint total=0,groups=(view.config.z+255)/256;
          for(uint i=0;i<groups;++i) { groupScratch[groups+i]=total; total+=groupScratch[i]; }
          uint base=view.config.y*5;
          arguments[base]=total; arguments[base+1]=1; arguments[base+2]=view.config.x;
          arguments[base+3]=0; arguments[base+4]=0;
      }
      kernel void meshlet_scatter(device const Cluster* clusters [[buffer(0)]],device const uint* source [[buffer(1)]],
          device uint* counts [[buffer(2)]],device uint* offsets [[buffer(3)]],device uint* indices [[buffer(4)]],
          device uint* arguments [[buffer(5)]],constant View& view [[buffer(6)]],device uint* groupScratch [[buffer(7)]],
          uint3 group [[threadgroup_position_in_grid]],uint lane [[thread_index_in_threadgroup]]) {
          uint id=group.x+1024*group.y;
          if(id>=view.config.z) return;
          uint groups=(view.config.z+255)/256;
          uint destination=view.config.x+groupScratch[groups+id/256]+offsets[id];
          for(uint i=lane;i<counts[id];i+=64) indices[destination+i]=source[clusters[id].range.x+i];
      }
      """
  }
#endif
