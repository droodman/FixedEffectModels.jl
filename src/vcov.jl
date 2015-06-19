using GLM, DataFrames
# An Abstract VCE model contains object needed to compute errors. Important methods are residuals, regressors, number of obs, degree of freedom

abstract AbstractVceModel
StatsBase.residuals(x::AbstractVceModel) = error("not defined")
regressors(x::AbstractVceModel) = error("not defined")
nobs(x::AbstractVceModel) = size(regressors(x), 1)
GLM.df_residual(x::AbstractVceModel) = size(regressors(x), 1)
function hatmatrix(x::AbstractVceModel) 
	temp = At_mul_B(regressors(x), regressors(x))
	H = inv(cholfact!(temp))
end


immutable type VceModel{T} <: AbstractVceModel
	regressors::Matrix{T} # If weight, matrix should be X\sqrt{W}
	residuals::Vector{T}
	nobs::Int
	df_residual::Int
end
StatsBase.residuals(x::VceModel) = x.residuals
regressors(x::VceModel) = x.regressors
nobs(x::VceModel) = x.nobs
GLM.df_residual(x::VceModel) = x.df_residual

immutable type VceModelHat{T} <: AbstractVceModel
	regressors::Matrix{T} # If weight, matrix should be X\sqrt{W}
	hatmatrix::Matrix{T} # If weight, matrix should be X\sqrt{W}
	residuals::Vector{T}
	nobs::Int
	df_residual::Int
end
StatsBase.residuals(x::VceModelHat) = x.residuals
regressors(x::VceModelHat) = x.regressors
hatmatrix(x::VceModelHat) = x.hatmatrix
nobs(x::VceModelHat) = x.nobs
GLM.df_residual(x::VceModelHat) = x.df_residual

# convert a linear model into VceModelHat
function VceModelHat(x::LinearModel) 
	VceModelHat(x.pp.X, inv(cholfact(x)), StatsBase.residuals(x), size(x.pp.X, 1), size(x.pp.X, 2))
end



# An AbstractVCE  should have two methods: allvars that returns variables needed in the dataframe, and vcov, that returns a covariance matrix
abstract AbstractVce
DataFrames.allvars(x::AbstractVce) = nothing
StatsBase.vcov(x::AbstractVce) = error("not defined")


immutable type VceSimple <: AbstractVce 
end

StatsBase.vcov(x::VceModel, t::VceSimple) = StatsBase.vcov(x)



#
# simple
#


function StatsBase.vcov(x::AbstractVceModel, t::VceSimple)
 	hatmatrix(x) * (sum(StatsBase.residuals(x).^2)/  df_residual(x))
end

StatsBase.vcov(x::AbstractVceModel, t::VceSimple, df) = StatsBase.vcov(x, t)


#
# White
#


immutable type VceWhite <: AbstractVce 
end

function StatsBase.vcov(x::AbstractVceModel, t::VceWhite, df::AbstractDataFrame) 
	Xu = broadcast(*,  regressors(x), StatsBase.residuals(x))
	S = At_mul_B(Xu, Xu)
	scale!(S, nobs(x)/df_residual(x))
	sandwich(x, S) 
end


function sandwich(x::AbstractVceModel, S::Matrix{Float64})
	H = hatmatrix(x)
	H * S * H
end


#
# HAC
#

immutable type VceHac <: AbstractVce
	time::Symbol
	nlag::Int
	weightfunction::Function
end

VceHac(time, nlag) = VceHac(time, nlag, (i, n) -> 1 - i/(n+1))

DataFrames.allvars(x::VceHac) = x.time

function StatsBase.vcov(x::AbstractVceModel, v::VceHac, df)
	time = df[v.time]
	nlag = v.nlag
	weights = map(i -> v.weightfunction(i, nlag), [1:nlag])

	Xu = broadcast(*,  regressors(x), StatsBase.residuals(x))
	rhos = Array(Matrix{Float64}, nlag)

	# 1 is juste White
	rhos[1] = At_mul_B(Xu, Xu)	

	for i in 2:nlags
		lagx = lag(x, i, time)
		isna = sum(isna(x), 2) + sum(isna(lagx), 2)
		rhos[i] = At_mul_B(x[!isna, :], lagx[!isna, :]) +  At_mul_B(lagx[!isna, :], x[!isna, :]) 
		scale!(rhos[i], weights[i] * (size(x, 1) - i) / (size(x, 1) -i - lenth(isna)))
	end
	S = sum(rhos)
	scale!(S, nobs(x)/df_residual(x))
	sandwich(x, S) 
end

function lag(x::Array, n::Int, time::Vector) 
	index = findin(time - n, time)
	lagx = DataArray(eltype(x), dim(x))
	lagx[index] = x[index]
	return(lagx)
end

#
# Cluster
#

immutable type VceCluster  <: AbstractVce
	clusters::Vector{Symbol}
end
VceCluster(x::Symbol) = VceCluster([x])

DataFrames.allvars(x::VceCluster) = x.clusters

# Cameron, Gelbach, & Miller (2011).
function StatsBase.vcov(x::AbstractVceModel, v::VceCluster, df::AbstractDataFrame) 
	df = df[v.clusters]
	S = fill(zero(Float64), (size(regressors(x), 2), size(regressors(x), 2)))
	for i in 1:length(v.clusters)
		for c in combinations(v.clusters, i)
			if rem(length(c), 2) == 1
				S += helper_cluster(x, group(df[c]))
			else
				S -= helper_cluster(x, group(df[c]))
			end
		end
	end
	scale!(S, (nobs(x) - 1) / df_residual(x))
	sandwich(x, S)
end

function helper_cluster(x::AbstractVceModel, f::PooledDataArray)
	X = regressors(x)
	residuals = StatsBase.residuals(x)
	pool = f.pool
	refs = f.refs

	# if only one obs by pool, use White, as in Petersen (2009) & Thomson (2011)
	if length(pool) == size(X, 1)
		Xu = broadcast(*,  regressors(x), StatsBase.residuals(x))
		At_mul_B(Xu, Xu)
		return(At_mul_B(Xu, Xu))
	else
		# otherwise
		X2 = fill(zero(Float64), (size(X, 2), length(f.pool)))
		for j in 1:size(X, 2)
			for i in 1:size(X, 1)
				X2[j, refs[i]] += X[i, j] * residuals[i]
			end
		end
		out = A_mul_Bt(X2, X2)
		scale!(out, length(pool) / length(pool - 1))
		return(out)
	end
end








